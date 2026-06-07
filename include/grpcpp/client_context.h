#ifndef GRPCPP_CLIENT_CONTEXT_H
#define GRPCPP_CLIENT_CONTEXT_H

#include <chrono>
#include <string>
#include <utility>
#include <vector>

namespace grpc {

class ClientContext {
 public:
  ClientContext() = default;

  void AddMetadata(const std::string& key, const std::string& value) {
    metadata_.emplace_back(key, value);
  }

  template <typename T>
  void set_deadline(const T& deadline) {
    deadline_ = std::chrono::system_clock::time_point(
        std::chrono::duration_cast<std::chrono::system_clock::duration>(
            deadline.time_since_epoch()));
  }

  std::chrono::system_clock::time_point deadline() const { return deadline_; }

  const std::vector<std::pair<std::string, std::string>>& metadata() const {
    return metadata_;
  }

  const std::vector<std::pair<std::string, std::string>>&
  GetServerInitialMetadata() const {
    return server_initial_metadata_;
  }

  const std::vector<std::pair<std::string, std::string>>&
  GetServerTrailingMetadata() const {
    return server_trailing_metadata_;
  }

  void SetServerInitialMetadata(
      std::vector<std::pair<std::string, std::string>> md) {
    server_initial_metadata_ = std::move(md);
  }

  void SetServerTrailingMetadata(
      std::vector<std::pair<std::string, std::string>> md) {
    server_trailing_metadata_ = std::move(md);
  }

 private:
  std::vector<std::pair<std::string, std::string>> metadata_;
  std::chrono::system_clock::time_point deadline_{};
  std::vector<std::pair<std::string, std::string>> server_initial_metadata_;
  std::vector<std::pair<std::string, std::string>> server_trailing_metadata_;
};

}  // namespace grpc

#endif  // GRPCPP_CLIENT_CONTEXT_H
