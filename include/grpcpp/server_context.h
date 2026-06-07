#ifndef GRPCPP_SERVER_CONTEXT_H
#define GRPCPP_SERVER_CONTEXT_H

#include <string>
#include <utility>
#include <vector>

namespace grpc {

class ServerContextBase {
 public:
  virtual ~ServerContextBase() = default;

  void AddInitialMetadata(const std::string& key, const std::string& value) {
    initial_metadata_.emplace_back(key, value);
  }

  void AddTrailingMetadata(const std::string& key, const std::string& value) {
    trailing_metadata_.emplace_back(key, value);
  }

  const std::vector<std::pair<std::string, std::string>>&
  initial_metadata() const {
    return initial_metadata_;
  }

  const std::vector<std::pair<std::string, std::string>>&
  trailing_metadata() const {
    return trailing_metadata_;
  }

 protected:
  std::vector<std::pair<std::string, std::string>> initial_metadata_;
  std::vector<std::pair<std::string, std::string>> trailing_metadata_;
};

class ServerContext : public ServerContextBase {
 public:
  ServerContext() = default;
};

class CallbackServerContext : public ServerContextBase {
 public:
  CallbackServerContext() = default;
};

}  // namespace grpc

#endif  // GRPCPP_SERVER_CONTEXT_H
