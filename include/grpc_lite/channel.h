#ifndef GRPC_LITE_CHANNEL_H_
#define GRPC_LITE_CHANNEL_H_

#include <chrono>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "status.h"
#include "stream.h"

namespace grpc_lite {

class ClientContext;
class ChannelImpl;

enum class SecurityMode {
    kInsecure,
    kTls,
};

struct ChannelOptions {
    SecurityMode security = SecurityMode::kInsecure;
    bool use_system_resolver = false;
    std::chrono::milliseconds keepalive_time{0};
    std::chrono::milliseconds keepalive_timeout{20000};
    std::size_t max_concurrent_streams = 100;
};

class Channel {
  public:
    ~Channel();

    static std::shared_ptr<Channel> Create(std::string target, ChannelOptions options = {});

    const std::string& target() const;
    const ChannelOptions& options() const;
    bool SupportsProtocolCompatibility() const;

    Status CallUnary(
        const std::string& method, const std::string& request_bytes, ClientContext* context,
        std::string* response_bytes
    );

    Status CallServerStreaming(
        const std::string& method, const std::string& request_bytes, ClientContext* context,
        std::vector<std::string>* response_messages
    );

    std::unique_ptr<ClientReader> StartServerStreaming(
        const std::string& method, const std::string& request_bytes, ClientContext* context
    );

    std::unique_ptr<ClientWriter> StartClientStreaming(
        const std::string& method, ClientContext* context
    );

    std::unique_ptr<ClientReaderWriter> StartBidiStreaming(
        const std::string& method, ClientContext* context
    );

    Status CallClientStreaming(
        const std::string& method, const std::vector<std::string>& request_messages,
        ClientContext* context, std::string* response_bytes
    );

    Status CallBidiStreaming(
        const std::string& method, const std::vector<std::string>& request_messages,
        ClientContext* context, std::vector<std::string>* response_messages
    );

  private:
    Channel(std::string target, ChannelOptions options);
    std::shared_ptr<ChannelImpl> impl();

    std::string target_;
    ChannelOptions options_;
    std::mutex impl_mutex_;
    std::shared_ptr<ChannelImpl> impl_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_CHANNEL_H_
