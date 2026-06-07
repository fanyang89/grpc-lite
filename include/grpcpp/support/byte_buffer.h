#ifndef GRPCPP_SUPPORT_BYTE_BUFFER_H
#define GRPCPP_SUPPORT_BYTE_BUFFER_H

#include <grpcpp/support/status.h>

#include <cstddef>
#include <string>

namespace grpc {

class Slice {
 public:
  Slice() = default;
  explicit Slice(const std::string& data) : data_(data) {}

  const unsigned char* begin() const {
    return reinterpret_cast<const unsigned char*>(data_.data());
  }

  std::size_t size() const { return data_.size(); }
  const std::string& data() const { return data_; }

 private:
  std::string data_;
};

class ByteBuffer {
 public:
  ByteBuffer() = default;
  ByteBuffer(const Slice* slices, std::size_t count) {
    for (std::size_t i = 0; i < count; ++i) {
      data_.append(slices[i].data());
    }
  }

  bool SerializeToString(std::string* output) const {
    if (output == nullptr) {
      return false;
    }
    *output = data_;
    return true;
  }

  bool ParseFromString(const std::string& input) {
    data_ = input;
    return true;
  }

  Status DumpToSingleSlice(Slice* slice) const {
    if (slice == nullptr) {
      return Status(StatusCode::INTERNAL, "slice output must not be null");
    }
    *slice = Slice(data_);
    return Status(StatusCode::OK, "");
  }

 private:
  std::string data_;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_BYTE_BUFFER_H
