#ifndef GRPC_LITE_CLIENT_CONTEXT_H_
#define GRPC_LITE_CLIENT_CONTEXT_H_

#include <chrono>
#include <string>
#include <utility>
#include <vector>

namespace grpc_lite {

class Channel;

class ClientContext {
 public:
  using MetadataEntry = std::pair<std::string, std::string>;

  void AddMetadata(std::string key, std::string value);
  void SetDeadline(std::chrono::system_clock::time_point deadline);

  const std::vector<MetadataEntry>& metadata() const;
  std::chrono::system_clock::time_point deadline() const;

  const std::vector<MetadataEntry>& server_initial_metadata() const;
  const std::vector<MetadataEntry>& server_trailing_metadata() const;

 private:
  friend class Channel;

  void SetServerInitialMetadata(std::vector<MetadataEntry> metadata);
  void SetServerTrailingMetadata(std::vector<MetadataEntry> metadata);

  std::vector<MetadataEntry> metadata_;
  std::chrono::system_clock::time_point deadline_{};
  std::vector<MetadataEntry> server_initial_metadata_;
  std::vector<MetadataEntry> server_trailing_metadata_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_CLIENT_CONTEXT_H_
