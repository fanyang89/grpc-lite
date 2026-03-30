#ifndef GRPC_LITE_SERVER_CONTEXT_H_
#define GRPC_LITE_SERVER_CONTEXT_H_

#include <string>
#include <utility>
#include <vector>

namespace grpc_lite {

class ServerContext {
 public:
  using MetadataEntry = std::pair<std::string, std::string>;

  void AddInitialMetadata(std::string key, std::string value);
  void AddTrailingMetadata(std::string key, std::string value);

  const std::vector<MetadataEntry>& initial_metadata() const;
  const std::vector<MetadataEntry>& trailing_metadata() const;

 private:
  std::vector<MetadataEntry> initial_metadata_;
  std::vector<MetadataEntry> trailing_metadata_;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVER_CONTEXT_H_
