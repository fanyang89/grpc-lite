#include "grpc_lite/server_context.h"

#include <utility>

namespace grpc_lite {

void ServerContext::AddInitialMetadata(std::string key, std::string value) {
  initial_metadata_.emplace_back(std::move(key), std::move(value));
}

void ServerContext::AddTrailingMetadata(std::string key, std::string value) {
  trailing_metadata_.emplace_back(std::move(key), std::move(value));
}

const std::vector<ServerContext::MetadataEntry>&
ServerContext::initial_metadata() const {
  return initial_metadata_;
}

const std::vector<ServerContext::MetadataEntry>&
ServerContext::trailing_metadata() const {
  return trailing_metadata_;
}

}  // namespace grpc_lite
