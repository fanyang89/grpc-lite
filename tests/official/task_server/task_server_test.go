package taskserver_test

import (
	"context"
	"errors"
	"io"
	"os"
	"slices"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/encoding/gzip"
	testpb "google.golang.org/grpc/interop/grpc_testing"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/status"
)

type payloadSize struct {
	plain, compressed int
}

type wireStats struct {
	mu       sync.Mutex
	encoding string
	payloads []payloadSize
}

func (*wireStats) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context   { return ctx }
func (*wireStats) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context { return ctx }
func (*wireStats) HandleConn(context.Context, stats.ConnStats)                       {}

func (s *wireStats) HandleRPC(_ context.Context, event stats.RPCStats) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch event := event.(type) {
	case *stats.InHeader:
		s.encoding = event.Compression
	case *stats.InPayload:
		s.payloads = append(s.payloads, payloadSize{event.Length, event.CompressedLength})
	}
}

func (s *wireStats) snapshot() (string, []payloadSize) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.encoding, slices.Clone(s.payloads)
}

func clientFor(t *testing.T, options ...grpc.DialOption) testpb.TestServiceClient {
	t.Helper()
	address := os.Getenv("GRPC_LITE_TASK_SERVER_ADDRESS")
	if address == "" {
		t.Skip("run through mise run interop-async to start the task server")
	}
	options = append(options, grpc.WithTransportCredentials(insecure.NewCredentials()))
	conn, err := grpc.NewClient(address, options...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return testpb.NewTestServiceClient(conn)
}

func TestCompressedInputStream(t *testing.T) {
	client := clientFor(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	stream, err := client.StreamingInputCall(ctx, grpc.UseCompressor(gzip.Name))
	if err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if err := stream.Send(&testpb.StreamingInputCallRequest{
			ExpectCompressed: &testpb.BoolValue{Value: true},
			Payload:          &testpb.Payload{Body: make([]byte, 64*1024)},
		}); err != nil {
			t.Fatal(err)
		}
	}
	response, err := stream.CloseAndRecv()
	if err != nil {
		t.Fatal(err)
	}
	if response.GetAggregatedPayloadSize() != 3*64*1024 {
		t.Fatalf("aggregated payload = %d", response.GetAggregatedPayloadSize())
	}

	mismatch, err := client.StreamingInputCall(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := mismatch.Send(&testpb.StreamingInputCallRequest{
		ExpectCompressed: &testpb.BoolValue{Value: true},
		Payload:          &testpb.Payload{Body: []byte("identity")},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := mismatch.CloseAndRecv(); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("compression mismatch status = %v", err)
	}
}

func TestMixedCompressionOutputStream(t *testing.T) {
	tracker := new(wireStats)
	client := clientFor(t, grpc.WithStatsHandler(tracker))
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	compressed := []bool{true, false, true}
	request := new(testpb.StreamingOutputCallRequest)
	for _, value := range compressed {
		request.ResponseParameters = append(request.ResponseParameters, &testpb.ResponseParameters{
			Size: 64 * 1024, Compressed: &testpb.BoolValue{Value: value},
		})
	}
	stream, err := client.StreamingOutputCall(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	for range compressed {
		response, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if len(response.GetPayload().GetBody()) != 64*1024 {
			t.Fatalf("response size = %d", len(response.GetPayload().GetBody()))
		}
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Fatalf("terminal receive = %v", err)
	}
	encoding, payloads := tracker.snapshot()
	if encoding != gzip.Name || len(payloads) != len(compressed) {
		t.Fatalf("wire stats: encoding=%q payloads=%v", encoding, payloads)
	}
	for index, size := range payloads {
		if compressed[index] && size.compressed >= size.plain {
			t.Errorf("message %d was not compressed: %+v", index, size)
		}
		if !compressed[index] && size.compressed != size.plain {
			t.Errorf("message %d was not identity: %+v", index, size)
		}
	}
}

func TestHandlerWaitIsolationAndCancellation(t *testing.T) {
	client := clientFor(t)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	streamCtx, cancelStream := context.WithCancel(ctx)
	defer cancelStream()
	stream, err := client.FullDuplexCall(streamCtx)
	if err != nil {
		t.Fatal(err)
	}
	request := &testpb.StreamingOutputCallRequest{
		ResponseParameters: []*testpb.ResponseParameters{{Size: 1, IntervalUs: 5_000_000}},
	}
	if err := stream.Send(request); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Header(); err != nil {
		t.Fatal(err)
	}
	// An unrelated unary call must progress on the same connection while the
	// response handler is sleeping on the server's only zio executor.
	unaryCtx, cancelUnary := context.WithTimeout(ctx, time.Second)
	defer cancelUnary()
	if _, err := client.EmptyCall(unaryCtx, new(testpb.Empty)); err != nil {
		t.Fatalf("unary call while handler is waiting: %v", err)
	}
	cancelStream()
	if _, err := stream.Recv(); status.Code(err) != codes.Canceled {
		t.Fatalf("cancelled delayed response = %v", err)
	}

	deadlineCtx, cancelDeadline := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancelDeadline()
	delayed, err := client.StreamingOutputCall(deadlineCtx, request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := delayed.Recv(); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("expired delayed response = %v", err)
	}
	followupCtx, cancelFollowup := context.WithTimeout(ctx, time.Second)
	defer cancelFollowup()
	if _, err := client.EmptyCall(followupCtx, new(testpb.Empty)); err != nil {
		t.Fatalf("unary call after cancelling handlers: %v", err)
	}
}

func TestResponseInterval(t *testing.T) {
	client := clientFor(t)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	stream, err := client.FullDuplexCall(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Header(); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	if err := stream.Send(&testpb.StreamingOutputCallRequest{
		ResponseParameters: []*testpb.ResponseParameters{{Size: 1, IntervalUs: 100_000}},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < 100*time.Millisecond {
		t.Fatalf("response arrived before requested interval: %v", elapsed)
	}
	if err := stream.CloseSend(); err != nil {
		t.Fatal(err)
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Fatalf("terminal receive = %v", err)
	}
}
