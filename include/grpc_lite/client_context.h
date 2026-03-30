#ifndef GRPC_LITE_CLIENT_CONTEXT_H_
#define GRPC_LITE_CLIENT_CONTEXT_H_

#include <chrono>
#include <string>
#include <utility>
#include <vector>

namespace grpc_lite {

class ClientContext {
 public:
  using MetadataEntry = std::pair<std::string, std::string>;

  void AddMetadata(std::string key, std::string value);
  void SetDeadline(std::chrono::system_clock::time_point deadline);

  const std::vector<MetadataEntry>& metadata() const;
  std::chrono::system_clock::time_point deadline() const;

 private:
  std::vector<MetadataEntry> metadata_;
  std::chrono::system_clock::time_point deadline_{};
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_CLIENT_CONTEXT_H_
