#ifndef GRPC_LITE_SERVER_H_
#define GRPC_LITE_SERVER_H_

#include <memory>
#include <string>
#include <vector>

#include "grpc_lite/status.h"

namespace grpc_lite {

class Service;

class Server {
 public:
  struct Listener {
    std::string address;
    bool use_tls = false;
  };

  explicit Server(std::vector<Listener> listeners);

  void AddService(Service* service);
  Status Start();
  void Shutdown();

  bool started() const;
  const std::vector<Listener>& listeners() const;

 private:
  std::vector<Listener> listeners_;
  std::vector<Service*> services_;
  bool started_ = false;
};

}  // namespace grpc_lite

#endif  // GRPC_LITE_SERVER_H_
