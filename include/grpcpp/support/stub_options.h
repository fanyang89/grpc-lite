#ifndef GRPCPP_SUPPORT_STUB_OPTIONS_H
#define GRPCPP_SUPPORT_STUB_OPTIONS_H

namespace grpc {

class StubOptions {
 public:
  StubOptions() = default;
  explicit StubOptions(const char* suffix_for_stats)
      : suffix_for_stats_(suffix_for_stats) {}

  void set_suffix_for_stats(const char* suffix_for_stats) {
    suffix_for_stats_ = suffix_for_stats;
  }
  const char* suffix_for_stats() const { return suffix_for_stats_; }

 private:
  const char* suffix_for_stats_ = nullptr;
};

}  // namespace grpc

#endif  // GRPCPP_SUPPORT_STUB_OPTIONS_H
