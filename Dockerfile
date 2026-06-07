FROM fedora:43

RUN dnf install -y clang18-tools-extra && dnf clean all

WORKDIR /grpc-lite

ENTRYPOINT ["/usr/bin/clang-format-18"]
