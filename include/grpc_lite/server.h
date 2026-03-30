#ifndef GRPC_LITE_SERVER_H_
#define GRPC_LITE_SERVER_H_

#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "grpc_lite/status.h"

namespace grpc_lite {

class ServerImpl;
class Service;

class Server {
 public:
  struct Listener {
    std::string address;
    bool use_tls = false;
  };

  explicit Server(std::vector<Listener> listeners);
  ~Server();

  void AddService(Service* service);
  Status Start();
  void Wait();
  void Shutdown();

  bool started() const;
  const std::vector<Listener>& listeners() const;

 private:
  friend class ServerImpl;

  Service* FindService(std::string_view path, std::string* method_name) const;

  std::vector<Listener> listeners_;
  std::vector<Service*> services_;
  std::unique_ptr<ServerImpl> impl_;
  bool started_ = false;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVER_H_
