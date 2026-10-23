package main

import (
	"context"
	"errors"
	"io"
	"testing"
	"time"

	"google.golang.org/grpc"
	testgrpc "google.golang.org/grpc/interop/grpc_testing"
)

func TestMessageSize(t *testing.T) {
	if got := messageSize(47, 0); got != 1048623 {
		t.Fatalf("first size = %d", got)
	}
	if got := messageSize(47, 1); got != 1056542 {
		t.Fatalf("second size = %d", got)
	}
	for sequence := range 10000 {
		size := messageSize(47, sequence)
		if size < 1024*1024 || size >= 1024*1024+65521 {
			t.Fatalf("size out of workload bounds: sequence=%d size=%d", sequence, size)
		}
		if size == messageSize(48, sequence) {
			t.Fatalf("seed did not change size at sequence=%d", sequence)
		}
	}
}

type receiveStream struct {
	grpc.BidiStreamingClient[testgrpc.StreamingOutputCallRequest, testgrpc.StreamingOutputCallResponse]
	response *testgrpc.StreamingOutputCallResponse
	err      error
}

func (s receiveStream) Recv() (*testgrpc.StreamingOutputCallResponse, error) {
	return s.response, s.err
}

func TestReceive(t *testing.T) {
	for _, name := range []string{"valid", "nil", "wrong-size", "wrong-type", "corrupt", "early-eof", "rpc-error"} {
		t.Run(name, func(t *testing.T) {
			response := &testgrpc.StreamingOutputCallResponse{Payload: &testgrpc.Payload{
				Type: testgrpc.PayloadType_COMPRESSABLE,
				Body: make([]byte, messageSize(47, 0)),
			}}
			stream := receiveStream{response: response}
			switch name {
			case "nil":
				stream.response = nil
			case "wrong-size":
				response.Payload.Body = response.Payload.Body[1:]
			case "wrong-type":
				response.Payload.Type = testgrpc.PayloadType(99)
			case "corrupt":
				response.Payload.Body[len(response.Payload.Body)-1] = 1
			case "early-eof":
				stream.err = io.EOF
			case "rpc-error":
				stream.err = context.DeadlineExceeded
			}
			err := receive(stream, 47, 0)
			if (err == nil) != (name == "valid") {
				t.Fatalf("receive error = %v", err)
			}
		})
	}
}

func TestPauseCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if err := pause(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatalf("pause error = %v", err)
	}
}
