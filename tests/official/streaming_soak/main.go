// streaming_soak drives the existing official FullDuplexCall peer; it is not a benchmark.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	testgrpc "google.golang.org/grpc/interop/grpc_testing"
)

const (
	requestsPerBatch    = 2
	responsesPerRequest = 8
	batchSize           = requestsPerBatch * responsesPerRequest
)

// Each request asks the native handler to enqueue more than its 8 MiB outbound
// capacity in one callback. Fixed grpc-go windows also disable BDP growth, so
// withholding Recv sustains pressure until the slow consumer drains responses.
func messageSize(seed uint64, sequence int) int {
	return 1024*1024 + int((seed+uint64(sequence)*7919)%65521)
}

func pause(ctx context.Context, delay time.Duration) error {
	select {
	case <-time.After(delay):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func receive(stream grpc.BidiStreamingClient[testgrpc.StreamingOutputCallRequest, testgrpc.StreamingOutputCallResponse], seed uint64, sequence int) error {
	response, err := stream.Recv()
	if err != nil {
		return fmt.Errorf("receive sequence=%d: %w", sequence, err)
	}
	payload := response.GetPayload()
	if payload == nil || payload.GetType() != testgrpc.PayloadType_COMPRESSABLE || len(payload.GetBody()) != messageSize(seed, sequence) {
		return fmt.Errorf("response shape mismatch sequence=%d size=%d expected=%d", sequence, len(payload.GetBody()), messageSize(seed, sequence))
	}
	for _, value := range payload.GetBody() {
		if value != 0 {
			return fmt.Errorf("nonzero response byte sequence=%d", sequence)
		}
	}
	return nil
}

func run(ctx context.Context, target string, duration time.Duration, seed uint64) error {
	conn, err := grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithStaticStreamWindowSize(65535),
		grpc.WithStaticConnWindowSize(65535))
	if err != nil {
		return fmt.Errorf("create client: %w", err)
	}
	defer conn.Close()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := testgrpc.NewTestServiceClient(conn).FullDuplexCall(ctx)
	if err != nil {
		return fmt.Errorf("open FullDuplexCall: %w", err)
	}

	// Only this goroutine sends. The main goroutine receives independently,
	// including while Send is flow-controlled. One batch bounds queued work.
	batches := make(chan int)
	sent := make(chan error, 1)
	senderDone := make(chan struct{})
	go func() {
		defer close(senderDone)
		for first := range batches {
			var sendErr error
			for offset := range requestsPerBatch {
				sequence := first + offset*responsesPerRequest
				parameters := make([]*testgrpc.ResponseParameters, responsesPerRequest)
				for index := range responsesPerRequest {
					parameters[index] = &testgrpc.ResponseParameters{Size: int32(messageSize(seed, sequence+index))}
				}
				request := &testgrpc.StreamingOutputCallRequest{
					ResponseType:       testgrpc.PayloadType_COMPRESSABLE,
					ResponseParameters: parameters,
					Payload:            &testgrpc.Payload{Type: testgrpc.PayloadType_COMPRESSABLE, Body: make([]byte, messageSize(seed, sequence))},
				}
				if sendErr = stream.Send(request); sendErr != nil {
					break
				}
			}
			sent <- sendErr
			if sendErr != nil {
				return
			}
		}
	}()
	defer func() {
		cancel()
		close(batches)
		<-senderDone
	}()

	start := time.Now()
	cycles := 0
	messages := 0
	for time.Since(start) < duration || cycles < 2 {
		select {
		case batches <- messages:
		case <-ctx.Done():
			return ctx.Err()
		}
		// Repeat a no-read phase followed by a slow drain on the SAME stream.
		if err := pause(ctx, 150*time.Millisecond); err != nil {
			return err
		}
		for offset := range batchSize {
			if err := pause(ctx, 10*time.Millisecond); err != nil {
				return err
			}
			if err := receive(stream, seed, messages+offset); err != nil {
				return err
			}
		}
		if err := <-sent; err != nil {
			return fmt.Errorf("send batch=%d: %w", cycles, err)
		}
		messages += batchSize
		cycles++
		if cycles == 1 || cycles%10 == 0 {
			fmt.Printf("progress cycles=%d messages=%d elapsed=%s\n", cycles, messages, time.Since(start).Round(time.Millisecond))
		}
	}
	if err := stream.CloseSend(); err != nil {
		return fmt.Errorf("half-close: %w", err)
	}
	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		return fmt.Errorf("expected OK terminal EOF after %d messages, got %v", messages, err)
	}
	fmt.Printf("PASS cycles=%d sent=%d received=%d terminal=OK elapsed=%s\n", cycles, cycles*requestsPerBatch, messages, time.Since(start).Round(time.Millisecond))
	return nil
}

func main() {
	target := flag.String("target", "127.0.0.1:10000", "native official peer address")
	duration := flag.Duration("duration", 30*time.Second, "minimum traffic duration before draining the last batch")
	timeout := flag.Duration("timeout", 60*time.Second, "RPC deadline including drain")
	seed := flag.Uint64("seed", 47, "deterministic message-size sequence seed")
	flag.Parse()
	if *duration < time.Second || *timeout <= *duration || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "require duration >= 1s, timeout > duration, and no positional arguments")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	fmt.Printf("workload=bidi-slow-large-v1 seed=%d duration=%s timeout=%s requests_per_batch=%d responses_per_request=%d window=65535 pause=150ms receive_delay=10ms\n", *seed, *duration, *timeout, requestsPerBatch, responsesPerRequest)
	if err := run(ctx, *target, *duration, *seed); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL: %v\n", err)
		os.Exit(1)
	}
}
