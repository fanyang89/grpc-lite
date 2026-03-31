#include <algorithm>
#include <cctype>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "google/protobuf/compiler/code_generator.h"
#include "google/protobuf/compiler/plugin.h"
#include "google/protobuf/descriptor.h"
#include "google/protobuf/io/coded_stream.h"

namespace {

using google::protobuf::Descriptor;
using google::protobuf::FileDescriptor;
using google::protobuf::MethodDescriptor;
using google::protobuf::ServiceDescriptor;
using google::protobuf::compiler::CodeGenerator;
using google::protobuf::compiler::GeneratorContext;
using google::protobuf::io::CodedOutputStream;
using google::protobuf::io::ZeroCopyOutputStream;

std::string StripProtoExtension(std::string_view path) {
  constexpr char kSuffix[] = ".proto";
  if (path.size() >= sizeof(kSuffix) - 1 &&
      path.compare(path.size() - (sizeof(kSuffix) - 1), sizeof(kSuffix) - 1,
                   kSuffix) == 0) {
    return std::string(path.substr(0, path.size() - (sizeof(kSuffix) - 1)));
  }
  return std::string(path);
}

std::vector<std::string> Split(std::string_view value, char delimiter) {
  std::vector<std::string> parts;
  std::string current;
  for (char ch : value) {
    if (ch == delimiter) {
      if (!current.empty()) {
        parts.push_back(current);
        current.clear();
      }
      continue;
    }
    current.push_back(ch);
  }
  if (!current.empty()) {
    parts.push_back(current);
  }
  return parts;
}

std::string HeaderGuard(const std::string& path) {
  std::string guard;
  guard.reserve(path.size() + 16);
  for (unsigned char ch : path) {
    if (std::isalnum(ch) != 0) {
      guard.push_back(static_cast<char>(std::toupper(ch)));
    } else {
      guard.push_back('_');
    }
  }
  guard.append("_");
  return guard;
}

std::string CIdentifier(std::string_view full_name) {
  std::string identifier(full_name);
  std::replace(identifier.begin(), identifier.end(), '.', '_');
  return identifier;
}

std::string EscapeForCString(std::string_view text) {
  std::string escaped;
  escaped.reserve(text.size());
  for (char ch : text) {
    switch (ch) {
      case '\\':
        escaped.append("\\\\");
        break;
      case '"':
        escaped.append("\\\"");
        break;
      default:
        escaped.push_back(ch);
        break;
    }
  }
  return escaped;
}

std::string MethodInputCType(const MethodDescriptor* method) {
  return CIdentifier(method->input_type()->full_name());
}

std::string MethodOutputCType(const MethodDescriptor* method) {
  return CIdentifier(method->output_type()->full_name());
}

void OpenNamespaces(std::ostringstream& stream,
                    const std::vector<std::string>& namespaces) {
  for (const std::string& part : namespaces) {
    stream << "namespace " << part << " {\n";
  }
  if (!namespaces.empty()) {
    stream << "\n";
  }
}

void CloseNamespaces(std::ostringstream& stream,
                     const std::vector<std::string>& namespaces) {
  if (!namespaces.empty()) {
    stream << "\n";
  }
  for (auto it = namespaces.rbegin(); it != namespaces.rend(); ++it) {
    stream << "}  // namespace " << *it << "\n";
  }
}

void WriteFile(GeneratorContext* context, const std::string& path,
               const std::string& content) {
  std::unique_ptr<ZeroCopyOutputStream> output(context->Open(path));
  CodedOutputStream coded_output(output.get());
  coded_output.WriteRaw(content.data(), static_cast<int>(content.size()));
}

std::string GenerateHeader(const FileDescriptor* file) {
  const std::string base_path = StripProtoExtension(file->name());
  const std::string header_path = base_path + ".grpc_lite.upb.h";
  const std::string upb_header = base_path + ".upb.h";
  const std::vector<std::string> namespaces = Split(file->package(), '.');

  std::ostringstream out;
  out << "#ifndef " << HeaderGuard(header_path) << "\n";
  out << "#define " << HeaderGuard(header_path) << "\n\n";
  out << "#include <string>\n";
  out << "#include <string_view>\n\n";
  out << "#include \"grpc_lite/service.h\"\n";
  out << "#include \"" << upb_header << "\"\n";
  out << "#include \"upb/mem/arena.h\"\n\n";

  OpenNamespaces(out, namespaces);

  for (int service_index = 0; service_index < file->service_count(); ++service_index) {
    const ServiceDescriptor* service = file->service(service_index);
    out << "class " << service->name() << " : public ::grpc_lite::Service {\n";
    out << " public:\n";
    out << "  ~" << service->name() << "() override = default;\n\n";
    out << "  std::string service_name() const override { return \""
        << EscapeForCString(service->full_name()) << "\"; }\n\n";
    out << "  ::grpc_lite::Status HandleUnary(std::string_view method,\n";
    out << "                                 std::string_view request,\n";
    out << "                                 ::grpc_lite::ServerContext* context,\n";
    out << "                                 std::string* response) override {\n";
    out << "    if (response == nullptr) {\n";
    out << "      return ::grpc_lite::Status(\n";
    out << "          ::grpc_lite::StatusCode::kInvalidArgument,\n";
    out << "          \"response output must not be null\");\n";
    out << "    }\n";
    out << "    response->clear();\n";

    for (int method_index = 0; method_index < service->method_count(); ++method_index) {
      const MethodDescriptor* method = service->method(method_index);
      out << (method_index == 0 ? "    if" : "    else if") << " (method == \""
          << EscapeForCString(method->name()) << "\") {\n";
      out << "      upb_Arena* arena = upb_Arena_New();\n";
      out << "      if (arena == nullptr) {\n";
      out << "        return ::grpc_lite::Status(\n";
      out << "            ::grpc_lite::StatusCode::kInternal,\n";
      out << "            \"failed to allocate upb arena\");\n";
      out << "      }\n";
      out << "      const ::" << MethodInputCType(method) << "* typed_request = ::"
          << MethodInputCType(method) << "_parse(request.data(), request.size(), arena);\n";
      out << "      if (typed_request == nullptr) {\n";
      out << "        upb_Arena_Free(arena);\n";
      out << "        return ::grpc_lite::Status(\n";
      out << "            ::grpc_lite::StatusCode::kInvalidArgument,\n";
      out << "            \"failed to parse "
          << EscapeForCString(method->input_type()->full_name()) << "\");\n";
      out << "      }\n";
      out << "      ::" << MethodOutputCType(method) << "* typed_response = ::"
          << MethodOutputCType(method) << "_new(arena);\n";
      out << "      if (typed_response == nullptr) {\n";
      out << "        upb_Arena_Free(arena);\n";
      out << "        return ::grpc_lite::Status(\n";
      out << "            ::grpc_lite::StatusCode::kInternal,\n";
      out << "            \"failed to allocate "
          << EscapeForCString(method->output_type()->full_name()) << "\");\n";
      out << "      }\n";
      out << "      ::grpc_lite::Status status = " << method->name()
          << "(context, typed_request, typed_response, arena);\n";
      out << "      if (!status.ok()) {\n";
      out << "        upb_Arena_Free(arena);\n";
      out << "        return status;\n";
      out << "      }\n";
      out << "      size_t serialized_size = 0;\n";
      out << "      char* serialized = ::" << MethodOutputCType(method)
          << "_serialize(typed_response, arena, &serialized_size);\n";
      out << "      if (serialized == nullptr) {\n";
      out << "        upb_Arena_Free(arena);\n";
      out << "        return ::grpc_lite::Status(\n";
      out << "            ::grpc_lite::StatusCode::kInternal,\n";
      out << "            \"failed to serialize "
          << EscapeForCString(method->output_type()->full_name()) << "\");\n";
      out << "      }\n";
      out << "      response->assign(serialized, serialized_size);\n";
      out << "      upb_Arena_Free(arena);\n";
      out << "      return status;\n";
      out << "    }\n";
    }

    out << "    return ::grpc_lite::Status(\n";
    out << "        ::grpc_lite::StatusCode::kUnimplemented,\n";
    out << "        \"unknown unary method for "
        << EscapeForCString(service->full_name()) << "\");\n";
    out << "  }\n\n";

    for (int method_index = 0; method_index < service->method_count(); ++method_index) {
      const MethodDescriptor* method = service->method(method_index);
      out << "  virtual ::grpc_lite::Status " << method->name() << "(\n";
      out << "      ::grpc_lite::ServerContext* context,\n";
      out << "      const ::" << MethodInputCType(method) << "* request,\n";
      out << "      ::" << MethodOutputCType(method) << "* response,\n";
      out << "      upb_Arena* arena) = 0;\n";
      if (method_index + 1 != service->method_count()) {
        out << "\n";
      }
    }
    out << "};\n\n";
  }

  CloseNamespaces(out, namespaces);
  out << "\n#endif  // " << HeaderGuard(header_path) << "\n";
  return out.str();
}

class Generator final : public CodeGenerator {
 public:
  bool Generate(const FileDescriptor* file, const std::string& parameter,
                GeneratorContext* generator_context,
                std::string* error) const override {
    if (!parameter.empty()) {
      *error = "grpc_lite_upb generator does not accept parameters";
      return false;
    }

    for (int service_index = 0; service_index < file->service_count(); ++service_index) {
      const ServiceDescriptor* service = file->service(service_index);
      for (int method_index = 0; method_index < service->method_count(); ++method_index) {
        const MethodDescriptor* method = service->method(method_index);
        if (method->client_streaming() || method->server_streaming()) {
          *error = "grpc-lite upb generator currently supports unary methods only";
          return false;
        }
      }
    }

    WriteFile(generator_context,
              StripProtoExtension(file->name()) + ".grpc_lite.upb.h",
              GenerateHeader(file));
    return true;
  }
};

}  // namespace

int main(int argc, char* argv[]) {
  Generator generator;
  return google::protobuf::compiler::PluginMain(argc, argv, &generator);
}
