#include <grpc_lite/cpp/client_stream.hpp>
#include <grpc_lite/cpp/server.hpp>

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

using namespace std::chrono_literals;

namespace {
constexpr auto kTimeoutNs = UINT64_C(5000000000);
constexpr char kMethod[] = "/example.Bounded/Work";
// Raw protobuf bytes: field 1, string "ok". No Protobuf runtime is needed.
const std::string kResponse = "\x0a\x02ok";

void Require(bool ok, const char* message) {
  if (!ok) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

// Application-controlled stand-in for blocking downstream work. The smoke tests
// hold the sole worker here, so saturation never depends on sleeps or RPC timing.
class WorkGate {
 public:
  void Run() {
    std::unique_lock<std::mutex> lock(mutex_);
    entered_ = true;
    changed_.notify_all();
    changed_.wait(lock, [&] { return released_; });
  }
  void WaitUntilEntered() {
    std::unique_lock<std::mutex> lock(mutex_);
    Require(changed_.wait_for(lock, 5s, [&] { return entered_; }),
            "worker did not start");
  }
  void Release() {
    std::lock_guard<std::mutex> lock(mutex_);
    released_ = true;
    changed_.notify_all();
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  bool entered_ = false;
  bool released_ = false;
};

// One worker, one total outstanding job, no waiting backlog. Contention itself
// rejects: a reactor never waits for a mutex, a queue slot, or application work.
class BoundedExecutor {
 public:
  explicit BoundedExecutor(WorkGate& work) : work_(work) {}
  ~BoundedExecutor() { Join(); }
  void Start() {
    std::unique_lock<std::mutex> lock(mutex_);
    worker_ = std::thread([this] { Run(); });
    ready_.wait(lock, [&] { return started_; });
  }

  // On rejection the caller still owns call. On acceptance only the worker does.
  bool TrySubmit(grpc_lite::ServerCall& call) {
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock() || closed_ || busy_) return false;
    slot_ = std::move(call);
    busy_ = true;
    ready_.notify_one();
    return true;
  }
  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    ready_.notify_one();
  }
  void Join() {
    Close();
    if (worker_.joinable()) worker_.join();
  }

 private:
  void Run() {
    std::unique_lock<std::mutex> lock(mutex_);
    started_ = true;
    ready_.notify_one();
    for (;;) {
      ready_.wait(lock, [&] { return closed_ || busy_; });
      if (!busy_) return;
      auto call = std::move(slot_);
      lock.unlock();
      try {
        work_.Run(); // Only the application worker may block.
        if (!call.cancelled() && !call.terminal()) {
          // This example has a single tiny response. Production streaming code
          // must handle WouldBlock with on_writable, not spin or wait here.
          if (!call.SendInitialMetadata().ok() || !call.Send(kResponse).ok() ||
              !call.Finish({}).ok()) {
            call.Abort();
          }
        }
      } catch (...) {
        call.Abort();
      }
      // Release retained ownership before reopening admission or joining.
      call = {};
      lock.lock();
      busy_ = false;
    }
  }

  WorkGate& work_;
  std::mutex mutex_;
  std::condition_variable ready_;
  grpc_lite::ServerCall slot_;
  bool busy_ = false;
  bool closed_ = false;
  bool started_ = false;
  std::thread worker_;
};

// A raw event-driven client for the executable smoke scenarios.
class Request {
 public:
  void Start(grpc_lite::Channel& channel) {
    grpc_lite::ClientStreamCallbacks callbacks;
    callbacks.on_message = [this](std::string payload, grpc_lite::Compression) {
      std::lock_guard<std::mutex> lock(mutex_);
      response_ += payload;
      return grpc_lite::ReceiveAction::Continue;
    };
    callbacks.on_terminal = [this](grpc_lite::Status status,
                                    grpc_lite::MetadataEntries) {
      std::lock_guard<std::mutex> lock(mutex_);
      status_ = std::move(status);
      done_ = true;
      completed_.notify_one();
    };
    grpc_lite::ClientStreamOptions options;
    options.has_timeout = true;
    options.timeout_ns = kTimeoutNs;
    Require(grpc_lite::ClientStream::Open(channel, kMethod, options,
                                          std::move(callbacks), &stream_).ok(),
            "open request failed");
    Require(stream_.Send("").ok(), "send empty protobuf request failed");
    Require(stream_.CloseSend().ok(), "half-close request failed");
  }
  void Expect(grpc_lite::StatusCode code, const std::string& payload) {
    std::unique_lock<std::mutex> lock(mutex_);
    Require(completed_.wait_for(lock, 5s, [&] { return done_; }),
            "request did not complete");
    if (status_.code() != code) {
      std::cerr << "expected status " << static_cast<int>(code) << ", got "
                << static_cast<int>(status_.code()) << ": " << status_.message()
                << '\n';
      Require(false, "unexpected RPC status");
    }
    Require(response_ == payload, "unexpected RPC response");
  }

 private:
  std::mutex mutex_;
  std::condition_variable completed_;
  bool done_ = false;
  grpc_lite::Status status_;
  std::string response_;
  // Destroy stream before its callback state.
  grpc_lite::ClientStream stream_;
};
} // namespace

int main(int argc, char** argv) {
  const std::string scenario = argc == 2 ? argv[1] : "success";
  Require(scenario == "success" || scenario == "overload" || scenario == "shutdown",
          "usage: grpc_lite_bounded_executor [success|overload|shutdown]");

  grpc_lite::Runtime runtime;
  Require(grpc_lite::Runtime::Create(&runtime).ok(), "runtime creation failed");
  WorkGate work;
  BoundedExecutor executor(work);
  // Runtime precedes all threads. Executor and callback state outlive Server.
  executor.Start();
  grpc_lite::Server server;
  Require(grpc_lite::Server::Create({}, &server).ok(), "server creation failed");
  grpc_lite::ServerStreamCallbacks callbacks;
  callbacks.on_remote_end = [&](grpc_lite::ServerStream& stream,
                                 const grpc_lite::ServerContext&) {
    grpc_lite::ServerCall call;
    Require(stream.Retain(&call).ok(), "retain failed");
    try {
      if (!executor.TrySubmit(call)) {
        if (!call.SendInitialMetadata().ok() ||
            !call.Finish({grpc_lite::StatusCode::ResourceExhausted,
                          "executor full"}).ok()) call.Abort();
      }
    } catch (...) {
      call.Abort();
    }
    // Neither borrowed stream nor context escapes this callback. The rejected
    // call is released here; an accepted call is released on the worker.
  };
  Require(server.RegisterStream(kMethod, {}, std::move(callbacks)).ok(),
          "register method failed");
  Require(server.Start().ok(), "start server failed");
  std::uint32_t port = 0;
  Require(server.Port(&port).ok() && port != 0, "get server port failed");
  grpc_lite::Channel channel;
  Require(grpc_lite::Channel::CreateManaged(
              &runtime, "127.0.0.1:" + std::to_string(port), {}, &channel).ok(),
          "channel creation failed");

  Request accepted;
  accepted.Start(channel);
  work.WaitUntilEntered();
  if (scenario != "success") {
    if (scenario == "shutdown") executor.Close();
    Request rejected;
    rejected.Start(channel);
    rejected.Expect(grpc_lite::StatusCode::ResourceExhausted, "");
    std::cout << "rejection: RESOURCE_EXHAUSTED\n";
  }

  // Stop application admission first, then stop transport admission (GOAWAY).
  // Accepted work is still held when graceful drain starts in the shutdown case.
  executor.Close();
  if (scenario == "shutdown") server.ShutdownGracefully(kTimeoutNs);
  work.Release();
  executor.Join(); // All retained ServerCalls are destroyed before Server.
  grpc_lite::ServerCall unsubmitted;
  Require(!executor.TrySubmit(unsubmitted), "closed executor accepted work");
  accepted.Expect(grpc_lite::StatusCode::Ok, kResponse);
  if (scenario != "shutdown") server.ShutdownGracefully(kTimeoutNs);
  server.Wait();
  channel.Shutdown();
  channel.Wait();
  std::cout << scenario << ": accepted call OK; worker joined; server drained\n";
}
