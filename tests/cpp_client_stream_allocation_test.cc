// Isolated C++ allocation characterization, not a transport integration test.
// These C stubs capture the public wrapper's actual private callback thunks.
// Replacement new is confined to this executable and armed only on this thread.
#include <grpc_lite/cpp/client_stream.hpp>

#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <exception>
#include <memory>
#include <new>
#include <sys/wait.h>
#include <unistd.h>

namespace {
thread_local int allocations_until_failure = -1;
thread_local bool allocation_failed = false;
thread_local std::size_t live_allocations = 0;

class FailAllocation {
 public:
  explicit FailAllocation(int offset) {
    assert(allocations_until_failure == -1);
    allocation_failed = false;
    allocations_until_failure = offset;
  }
  ~FailAllocation() { allocations_until_failure = -1; }
  FailAllocation(const FailAllocation&) = delete;
  FailAllocation& operator=(const FailAllocation&) = delete;
};

unsigned opens = 0;
unsigned destroys = 0;
unsigned callback_count = 0;
grpc_lite_client_stream_callbacks captured = GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
constexpr char long_bytes[] =
    "a conversion payload deliberately longer than small string storage in either C++ runtime";
constexpr int expected_termination = 73;

void ConversionTerminated() noexcept {
  // A generic signal, assertion, or unrelated terminate is not a passing test.
  if (!allocation_failed || callback_count != 0) std::_Exit(74);
  const auto exception = std::current_exception();
  if (!exception) std::_Exit(75);
  try {
    std::rethrow_exception(exception);
  } catch (const std::bad_alloc&) {
    std::_Exit(expected_termination);
  } catch (...) {
    std::_Exit(76);
  }
}
}  // namespace

// No aligned/array allocation is injected: the tested make_unique, std::string,
// and vector allocations all use ordinary scalar new. The build disables the
// compiler's assumption that replacement new has no observable side effects.
void* operator new(std::size_t size) {
  if (allocations_until_failure >= 0) {
    if (allocations_until_failure-- == 0) {
      allocations_until_failure = -1;
      allocation_failed = true;
      throw std::bad_alloc();
    }
  }
  if (void* allocation = std::malloc(size == 0 ? 1 : size)) {
    ++live_allocations;
    return allocation;
  }
  throw std::bad_alloc();
}

void operator delete(void* allocation) noexcept {
  if (allocation != nullptr) {
    assert(live_allocations != 0);
    --live_allocations;
    std::free(allocation);
  }
}
void operator delete(void* allocation, std::size_t) noexcept {
  ::operator delete(allocation);
}

struct grpc_lite_client_stream {};
struct grpc_lite_metadata_view {};
namespace {
grpc_lite_client_stream fake_stream;
grpc_lite_metadata_view fake_metadata;
}  // namespace

extern "C" {
grpc_lite_error grpc_lite_channel_open_stream(
    grpc_lite_channel*, grpc_lite_bytes_view,
    const grpc_lite_client_stream_options*,
    const grpc_lite_client_stream_callbacks* callbacks,
    grpc_lite_client_stream** out) {
  ++opens;
  captured = *callbacks;
  *out = &fake_stream;
  return GRPC_LITE_OK;
}
void grpc_lite_client_stream_destroy(grpc_lite_client_stream* stream) {
  if (stream == nullptr) return;
  assert(stream == &fake_stream);
  ++destroys;
  captured = GRPC_LITE_CLIENT_STREAM_CALLBACKS_INIT;
}
void grpc_lite_channel_destroy(grpc_lite_channel* channel) {
  assert(channel == nullptr);
}
std::size_t grpc_lite_metadata_view_count(const grpc_lite_metadata_view* view) {
  assert(view == &fake_metadata);
  return 1;
}
grpc_lite_error grpc_lite_metadata_view_at(
    const grpc_lite_metadata_view* view, std::size_t index,
    grpc_lite_metadata_entry_view* out) {
  assert(view == &fake_metadata && index == 0);
  out->key = grpc_lite::internal::Bytes(long_bytes);
  out->value = grpc_lite::internal::Bytes(long_bytes);
  return GRPC_LITE_OK;
}
}  // extern "C"

namespace {
void TestCallbackStateAllocation() {
  grpc_lite::Channel channel;
  // Establish an owned output first: throwing Open must not replace/destroy it.
  std::weak_ptr<int> original_weak;
  const auto baseline = live_allocations;
  {
    grpc_lite::ClientStream stream;
    grpc_lite::ClientStreamCallbacks original;
    auto original_token = std::make_shared<int>(1);
    original_weak = original_token;
    original.on_remote_end = [token = std::move(original_token)] {
      ++callback_count;
    };
    assert(grpc_lite::ClientStream::Open(channel, "method", {},
                                        std::move(original), &stream).ok());
    const auto original_state = captured.user_data;
    const unsigned opens_before = opens;
    const unsigned destroys_before = destroys;
    const auto owned_baseline = live_allocations;
    {
      auto token = std::make_shared<int>(2);
      std::weak_ptr<int> weak = token;
      grpc_lite::ClientStreamCallbacks callbacks;
      callbacks.on_remote_end = [token = std::move(token)] { ++callback_count; };
      // All argument allocations precede arming; moving these arguments does
      // not allocate, so the next new is make_unique<CallbackState> in Open.
      std::string method = "method";
      bool threw = false;
      {
        FailAllocation fail(0);
        try {
          (void)grpc_lite::ClientStream::Open(
              channel, std::move(method), {}, std::move(callbacks), &stream);
        } catch (const std::bad_alloc&) {
          threw = true;
        }
      }
      assert(threw && allocation_failed);
      callbacks = {};
      assert(weak.expired());
      assert(!original_weak.expired());
      assert(opens == opens_before && destroys == destroys_before);
      assert(captured.user_data == original_state);
      assert(callback_count == 0);
    }
    assert(live_allocations == owned_baseline);
  }
  assert(original_weak.expired());
  original_weak.reset();
  assert(live_allocations == baseline);
  assert(opens == 1 && destroys == 1);
}

enum class Conversion { Headers, Message, Terminal };

void InvokeConversion(Conversion conversion) {
  // Bytes takes string_view; no temporary std::string allocation in the driver.
  const auto bytes = grpc_lite::internal::Bytes(long_bytes);
  switch (conversion) {
    case Conversion::Headers:
      captured.on_headers(captured.user_data, &fake_stream, &fake_metadata);
      break;
    case Conversion::Message:
      (void)captured.on_message(captured.user_data, &fake_stream, bytes, 0);
      break;
    case Conversion::Terminal:
      captured.on_terminal(captured.user_data, &fake_stream, 8, bytes,
                           &fake_metadata);
      break;
  }
}

void ExpectConversionTermination(Conversion conversion, int offset) {
  const pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    alarm(5);
    std::set_terminate(&ConversionTerminated);
    FailAllocation fail(offset);
    InvokeConversion(conversion);
    std::_Exit(77);  // Returning instead of terminating is a failure.
  }
  int status = 0;
  pid_t waited;
  do {
    waited = waitpid(child, &status, 0);
  } while (waited == -1 && errno == EINTR);
  assert(waited == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == expected_termination);
}

void TestConversionAllocationContract() {
  const auto baseline = live_allocations;
  {
    grpc_lite::Channel channel;
    grpc_lite::ClientStream stream;
    grpc_lite::ClientStreamCallbacks callbacks;
    callbacks.on_headers = [](grpc_lite::MetadataEntries) { ++callback_count; };
    callbacks.on_message = [](std::string, grpc_lite::Compression) {
      ++callback_count;
      return grpc_lite::ReceiveAction::Continue;
    };
    callbacks.on_terminal = [](grpc_lite::Status, grpc_lite::MetadataEntries) {
      ++callback_count;
    };
    assert(grpc_lite::ClientStream::Open(channel, "method", {},
                                        std::move(callbacks), &stream).ok());
    // Headers: vector reserve, then each long metadata string (evaluation order
    // of key/value is unspecified). Message: payload string. Terminal: status
    // string, vector reserve, then each metadata string.
    for (int offset = 0; offset != 3; ++offset)
      ExpectConversionTermination(Conversion::Headers, offset);
    ExpectConversionTermination(Conversion::Message, 0);
    for (int offset = 0; offset != 4; ++offset)
      ExpectConversionTermination(Conversion::Terminal, offset);
    assert(callback_count == 0);
    // Parent was never armed. Check ordinary callbacks and destruction still work.
    InvokeConversion(Conversion::Headers);
    InvokeConversion(Conversion::Message);
    InvokeConversion(Conversion::Terminal);
    assert(callback_count == 3);
  }
  assert(live_allocations == baseline);
  assert(opens == 2 && destroys == 2);
}
}  // namespace

int main() {
  TestCallbackStateAllocation();
  TestConversionAllocationContract();
}
