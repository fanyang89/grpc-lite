#pragma once

#if defined(GRPC_LITE_PROTO_USE_CPP26_META)
#include "../third_party/struct_proto26/include/proto3.hpp"
#else

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <variant>
#include <vector>

#include "refl.hpp"

namespace proto3 {

struct field_number_t : refl::attr::usage::field {
    int number;

    constexpr explicit field_number_t(int n) : number(n) {}
};

constexpr field_number_t field(int n) {
    return field_number_t{n};
}

struct skip_t : refl::attr::usage::field {};

constexpr inline skip_t skip{};

struct zigzag_t : refl::attr::usage::field {};

constexpr inline zigzag_t zigzag{};

struct fixed_t : refl::attr::usage::field {};

constexpr inline fixed_t fixed{};

struct bytes_t : refl::attr::usage::field {};

constexpr inline bytes_t bytes{};

struct unknown_fields_t : refl::attr::usage::field {};

constexpr inline unknown_fields_t unknown_fields{};

enum class wire_type : std::uint8_t {
    VARINT = 0,
    I64 = 1,
    LEN = 2,
    I32 = 5,
};

template <class T>
using remove_cvref_t = typename std::remove_cv<typename std::remove_reference<T>::type>::type;

template <class T>
struct is_vector : std::false_type {};

template <class T, class A>
struct is_vector<std::vector<T, A>> : std::true_type {};
template <class T>
constexpr bool is_vector_v = is_vector<T>::value;

template <class T>
struct is_map : std::false_type {};

template <class K, class V, class C, class A>
struct is_map<std::map<K, V, C, A>> : std::true_type {
    using key_type = K;
    using mapped_type = V;
};

template <class K, class V, class H, class E, class A>
struct is_map<std::unordered_map<K, V, H, E, A>> : std::true_type {
    using key_type = K;
    using mapped_type = V;
};
template <class T>
constexpr bool is_map_v = is_map<T>::value;

template <class T>
struct is_optional : std::false_type {};

template <class T>
struct is_optional<std::optional<T>> : std::true_type {};
template <class T>
constexpr bool is_optional_v = is_optional<T>::value;

template <class T>
struct is_variant : std::false_type {};

template <class... T>
struct is_variant<std::variant<T...>> : std::true_type {};
template <class T>
constexpr bool is_variant_v = is_variant<T>::value;

template <class T>
constexpr bool is_message_v = std::is_class<T>::value && !std::is_same<T, std::string>::value &&
    !is_vector_v<T> && !is_map_v<T> && !is_optional_v<T> && !is_variant_v<T>;

inline constexpr int kMinFieldNumber = 1;
inline constexpr int kMaxFieldNumber = 536870911;
inline constexpr int kReservedFirst = 19000;
inline constexpr int kReservedLast = 19999;

template <class To, class From>
To bit_cast_value(const From& from) {
    static_assert(sizeof(To) == sizeof(From), "proto3: bit_cast size mismatch");
    To to{};
    std::memcpy(&to, &from, sizeof(To));
    return to;
}

inline void write_varint(std::string& out, std::uint64_t v) {
    while (v >= 0x80) {
        out.push_back(static_cast<char>((v & 0x7F) | 0x80));
        v >>= 7;
    }
    out.push_back(static_cast<char>(v));
}

inline std::uint64_t read_varint(std::string_view& in) {
    std::uint64_t result = 0;
    int shift = 0;
    while (!in.empty()) {
        std::uint8_t byte = static_cast<std::uint8_t>(in.front());
        in.remove_prefix(1);
        result |= std::uint64_t(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            return result;
        }
        shift += 7;
        if (shift >= 70) {
            throw std::runtime_error("proto3: varint too long");
        }
    }
    throw std::runtime_error("proto3: truncated varint");
}

inline void write_tag(std::string& out, int field_num, wire_type wt) {
    write_varint(out, (std::uint64_t(field_num) << 3) | static_cast<std::uint64_t>(wt));
}

inline void write_fixed32(std::string& out, std::uint32_t bits) {
    for (int i = 0; i < 4; ++i) {
        out.push_back(static_cast<char>((bits >> (i * 8)) & 0xFF));
    }
}

inline void write_fixed64(std::string& out, std::uint64_t bits) {
    for (int i = 0; i < 8; ++i) {
        out.push_back(static_cast<char>((bits >> (i * 8)) & 0xFF));
    }
}

inline std::uint32_t read_fixed32(std::string_view& in) {
    if (in.size() < 4) {
        throw std::runtime_error("proto3: truncated fixed32");
    }
    std::uint32_t bits = 0;
    for (int i = 0; i < 4; ++i) {
        bits |= std::uint32_t(static_cast<std::uint8_t>(in[i])) << (i * 8);
    }
    in.remove_prefix(4);
    return bits;
}

inline std::uint64_t read_fixed64(std::string_view& in) {
    if (in.size() < 8) {
        throw std::runtime_error("proto3: truncated fixed64");
    }
    std::uint64_t bits = 0;
    for (int i = 0; i < 8; ++i) {
        bits |= std::uint64_t(static_cast<std::uint8_t>(in[i])) << (i * 8);
    }
    in.remove_prefix(8);
    return bits;
}

template <class T>
constexpr wire_type scalar_wire_type() {
    return std::is_same<T, float>::value      ? wire_type::I32
        : std::is_same<T, double>::value      ? wire_type::I64
        : std::is_same<T, std::string>::value ? wire_type::LEN
                                              : wire_type::VARINT;
}

template <class T>
void write_scalar(std::string& out, const T& v) {
    if constexpr (std::is_same<T, bool>::value) {
        write_varint(out, v ? 1u : 0u);
    } else if constexpr (std::is_same<T, float>::value) {
        write_fixed32(out, bit_cast_value<std::uint32_t>(v));
    } else if constexpr (std::is_same<T, double>::value) {
        write_fixed64(out, bit_cast_value<std::uint64_t>(v));
    } else if constexpr (std::is_same<T, std::string>::value) {
        write_varint(out, v.size());
        out.append(v);
    } else if constexpr (std::is_enum<T>::value) {
        using U = typename std::underlying_type<T>::type;
        write_varint(out, std::uint64_t(std::int64_t(static_cast<U>(v))));
    } else if constexpr (std::is_signed<T>::value) {
        write_varint(out, std::uint64_t(std::int64_t(v)));
    } else {
        write_varint(out, std::uint64_t(v));
    }
}

template <class T>
void read_scalar(std::string_view& in, T& v) {
    if constexpr (std::is_same<T, bool>::value) {
        v = read_varint(in) != 0;
    } else if constexpr (std::is_same<T, float>::value) {
        const std::uint32_t bits = read_fixed32(in);
        v = bit_cast_value<float>(bits);
    } else if constexpr (std::is_same<T, double>::value) {
        const std::uint64_t bits = read_fixed64(in);
        v = bit_cast_value<double>(bits);
    } else if constexpr (std::is_same<T, std::string>::value) {
        std::uint64_t len = read_varint(in);
        if (in.size() < len) {
            throw std::runtime_error("proto3: truncated string");
        }
        v.assign(in.data(), static_cast<std::size_t>(len));
        in.remove_prefix(static_cast<std::size_t>(len));
    } else if constexpr (std::is_enum<T>::value) {
        using U = typename std::underlying_type<T>::type;
        v = static_cast<T>(static_cast<U>(read_varint(in)));
    } else {
        v = static_cast<T>(read_varint(in));
    }
}

template <class T>
bool is_default_scalar(const T& v) {
    if constexpr (std::is_same<T, std::string>::value) {
        return v.empty();
    } else if constexpr (std::is_arithmetic<T>::value || std::is_enum<T>::value) {
        return v == T{};
    } else {
        return false;
    }
}

template <class T>
void serialize_into(std::string& out, const T& msg);
template <class T>
void deserialize_from(std::string_view in, T& msg);

template <class T>
void encode_field_present(std::string& out, int fn, const T& v) {
    if constexpr (is_message_v<T>) {
        write_tag(out, fn, wire_type::LEN);
        std::string buf;
        serialize_into(buf, v);
        write_varint(out, buf.size());
        out.append(buf);
    } else {
        write_tag(out, fn, scalar_wire_type<T>());
        write_scalar(out, v);
    }
}

template <class T>
void encode_field(std::string& out, int fn, const T& v) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        using Inner = typename U::value_type;
        static_assert(
            !is_vector_v<Inner> && !is_map_v<Inner> && !is_variant_v<Inner> &&
                !is_optional_v<Inner>,
            "std::optional<T> requires T to be a scalar, string, or message"
        );
        if (v.has_value()) {
            encode_field_present<Inner>(out, fn, *v);
        }
    } else if constexpr (is_vector_v<U>) {
        using E = typename U::value_type;
        if (v.empty()) {
            return;
        }
        if constexpr (is_message_v<E> || std::is_same<E, std::string>::value) {
            for (const auto& e : v) {
                write_tag(out, fn, wire_type::LEN);
                if constexpr (is_message_v<E>) {
                    std::string buf;
                    serialize_into(buf, e);
                    write_varint(out, buf.size());
                    out.append(buf);
                } else {
                    write_scalar(out, e);
                }
            }
        } else {
            std::string buf;
            for (const auto& e : v) {
                write_scalar(buf, e);
            }
            write_tag(out, fn, wire_type::LEN);
            write_varint(out, buf.size());
            out.append(buf);
        }
    } else if constexpr (is_map_v<U>) {
        using K = typename is_map<U>::key_type;
        using V = typename is_map<U>::mapped_type;
        for (const auto& kv : v) {
            std::string entry;
            encode_field_present<K>(entry, 1, kv.first);
            encode_field_present<V>(entry, 2, kv.second);
            write_tag(out, fn, wire_type::LEN);
            write_varint(out, entry.size());
            out.append(entry);
        }
    } else if constexpr (is_message_v<U>) {
        write_tag(out, fn, wire_type::LEN);
        std::string buf;
        serialize_into(buf, v);
        write_varint(out, buf.size());
        out.append(buf);
    } else {
        if (!is_default_scalar(v)) {
            write_tag(out, fn, scalar_wire_type<U>());
            write_scalar(out, v);
        }
    }
}

template <class T>
void write_zigzag_varint(std::string& out, T v) {
    static_assert(
        std::is_integral<T>::value && std::is_signed<T>::value,
        "proto3::zigzag requires a signed integer field"
    );
    using U = typename std::make_unsigned<T>::type;
    constexpr int bits = static_cast<int>(sizeof(T) * 8);
    U z = static_cast<U>(static_cast<U>(v) << 1) ^ static_cast<U>(v >> (bits - 1));
    write_varint(out, std::uint64_t(z));
}

template <class T>
void read_zigzag_varint(std::string_view& in, T& v) {
    static_assert(
        std::is_integral<T>::value && std::is_signed<T>::value,
        "proto3::zigzag requires a signed integer field"
    );
    using U = typename std::make_unsigned<T>::type;
    U z = static_cast<U>(read_varint(in));
    v = static_cast<T>((z >> 1) ^ -static_cast<U>(z & 1));
}

template <class T>
void encode_field_zz(std::string& out, int fn, const T& v) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        if (v.has_value()) {
            write_tag(out, fn, wire_type::VARINT);
            write_zigzag_varint(out, *v);
        }
    } else if constexpr (is_vector_v<U>) {
        if (v.empty()) {
            return;
        }
        std::string buf;
        for (const auto& e : v) {
            write_zigzag_varint(buf, e);
        }
        write_tag(out, fn, wire_type::LEN);
        write_varint(out, buf.size());
        out.append(buf);
    } else if (v != U{}) {
        write_tag(out, fn, wire_type::VARINT);
        write_zigzag_varint(out, v);
    }
}

template <class T>
void check_fixed_element_type() {
    static_assert(
        std::is_integral<T>::value && !std::is_same<T, bool>::value,
        "proto3::fixed requires a non-bool integer field"
    );
    static_assert(
        sizeof(T) == 4 || sizeof(T) == 8, "proto3::fixed requires a 4- or 8-byte integer"
    );
}

template <class T>
constexpr wire_type fixed_wire_type() {
    return sizeof(T) == 4 ? wire_type::I32 : wire_type::I64;
}

template <class T>
void write_fixed_value(std::string& out, T v) {
    if constexpr (sizeof(T) == 4) {
        write_fixed32(out, bit_cast_value<std::uint32_t>(v));
    } else {
        write_fixed64(out, bit_cast_value<std::uint64_t>(v));
    }
}

template <class T>
void read_fixed_value(std::string_view& in, T& v) {
    if constexpr (sizeof(T) == 4) {
        const std::uint32_t bits = read_fixed32(in);
        v = bit_cast_value<T>(bits);
    } else {
        const std::uint64_t bits = read_fixed64(in);
        v = bit_cast_value<T>(bits);
    }
}

template <class T>
void encode_field_fx(std::string& out, int fn, const T& v) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        using Inner = typename U::value_type;
        check_fixed_element_type<Inner>();
        if (v.has_value()) {
            write_tag(out, fn, fixed_wire_type<Inner>());
            write_fixed_value(out, *v);
        }
    } else if constexpr (is_vector_v<U>) {
        using E = typename U::value_type;
        check_fixed_element_type<E>();
        if (v.empty()) {
            return;
        }
        std::string buf;
        for (const auto& e : v) {
            write_fixed_value(buf, e);
        }
        write_tag(out, fn, wire_type::LEN);
        write_varint(out, buf.size());
        out.append(buf);
    } else {
        check_fixed_element_type<U>();
        if (v != U{}) {
            write_tag(out, fn, fixed_wire_type<U>());
            write_fixed_value(out, v);
        }
    }
}

inline void skip_field(std::string_view& in, wire_type wt) {
    switch (wt) {
        case wire_type::VARINT:
            read_varint(in);
            return;
        case wire_type::I64:
            if (in.size() < 8) {
                throw std::runtime_error("proto3: truncated I64");
            }
            in.remove_prefix(8);
            return;
        case wire_type::LEN: {
            std::uint64_t len = read_varint(in);
            if (in.size() < len) {
                throw std::runtime_error("proto3: truncated LEN");
            }
            in.remove_prefix(static_cast<std::size_t>(len));
            return;
        }
        case wire_type::I32:
            if (in.size() < 4) {
                throw std::runtime_error("proto3: truncated I32");
            }
            in.remove_prefix(4);
            return;
    }
    throw std::runtime_error("proto3: unknown wire type");
}

template <class T>
void decode_field(std::string_view& in, T& v, wire_type wt) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        if (!v.has_value()) {
            v.emplace();
        }
        decode_field(in, *v, wt);
    } else if constexpr (is_vector_v<U>) {
        using E = typename U::value_type;
        if constexpr (is_message_v<E>) {
            std::uint64_t len = read_varint(in);
            if (in.size() < len) {
                throw std::runtime_error("proto3: truncated message");
            }
            E e{};
            deserialize_from(std::string_view(in.data(), static_cast<std::size_t>(len)), e);
            in.remove_prefix(static_cast<std::size_t>(len));
            v.push_back(std::move(e));
        } else if constexpr (std::is_same<E, std::string>::value) {
            E e;
            read_scalar(in, e);
            v.push_back(std::move(e));
        } else if (wt == wire_type::LEN) {
            std::uint64_t len = read_varint(in);
            if (in.size() < len) {
                throw std::runtime_error("proto3: truncated packed");
            }
            std::string_view sub(in.data(), static_cast<std::size_t>(len));
            in.remove_prefix(static_cast<std::size_t>(len));
            while (!sub.empty()) {
                E e;
                read_scalar(sub, e);
                v.push_back(e);
            }
        } else {
            E e;
            read_scalar(in, e);
            v.push_back(e);
        }
    } else if constexpr (is_map_v<U>) {
        using K = typename is_map<U>::key_type;
        using V = typename is_map<U>::mapped_type;
        std::uint64_t len = read_varint(in);
        if (in.size() < len) {
            throw std::runtime_error("proto3: truncated map entry");
        }
        std::string_view sub(in.data(), static_cast<std::size_t>(len));
        in.remove_prefix(static_cast<std::size_t>(len));
        K key{};
        V val{};
        while (!sub.empty()) {
            std::uint64_t etag = read_varint(sub);
            int efn = static_cast<int>(etag >> 3);
            wire_type ewt = static_cast<wire_type>(etag & 0x7);
            if (efn == 1) {
                decode_field(sub, key, ewt);
            } else if (efn == 2) {
                decode_field(sub, val, ewt);
            } else {
                skip_field(sub, ewt);
            }
        }
        v.insert_or_assign(std::move(key), std::move(val));
    } else if constexpr (is_message_v<U>) {
        std::uint64_t len = read_varint(in);
        if (in.size() < len) {
            throw std::runtime_error("proto3: truncated message");
        }
        deserialize_from(std::string_view(in.data(), static_cast<std::size_t>(len)), v);
        in.remove_prefix(static_cast<std::size_t>(len));
    } else {
        read_scalar(in, v);
    }
}

template <class T>
void decode_field_zz(std::string_view& in, T& v, wire_type wt) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        if (!v.has_value()) {
            v.emplace();
        }
        read_zigzag_varint(in, *v);
    } else if constexpr (is_vector_v<U>) {
        using E = typename U::value_type;
        if (wt == wire_type::LEN) {
            std::uint64_t len = read_varint(in);
            if (in.size() < len) {
                throw std::runtime_error("proto3: truncated packed");
            }
            std::string_view sub(in.data(), static_cast<std::size_t>(len));
            in.remove_prefix(static_cast<std::size_t>(len));
            while (!sub.empty()) {
                E e;
                read_zigzag_varint(sub, e);
                v.push_back(e);
            }
        } else {
            E e;
            read_zigzag_varint(in, e);
            v.push_back(e);
        }
    } else {
        read_zigzag_varint(in, v);
    }
}

template <class T>
void decode_field_fx(std::string_view& in, T& v, wire_type wt) {
    using U = remove_cvref_t<T>;
    if constexpr (is_optional_v<U>) {
        using Inner = typename U::value_type;
        check_fixed_element_type<Inner>();
        if (!v.has_value()) {
            v.emplace();
        }
        read_fixed_value(in, *v);
    } else if constexpr (is_vector_v<U>) {
        using E = typename U::value_type;
        check_fixed_element_type<E>();
        if (wt == wire_type::LEN) {
            std::uint64_t len = read_varint(in);
            if (in.size() < len) {
                throw std::runtime_error("proto3: truncated packed");
            }
            std::string_view sub(in.data(), static_cast<std::size_t>(len));
            in.remove_prefix(static_cast<std::size_t>(len));
            while (!sub.empty()) {
                E e;
                read_fixed_value(sub, e);
                v.push_back(e);
            }
        } else {
            E e;
            read_fixed_value(in, e);
            v.push_back(e);
        }
    } else {
        check_fixed_element_type<U>();
        read_fixed_value(in, v);
    }
}

template <class Descriptor>
constexpr int field_number_at(Descriptor member, std::size_t index) {
    if constexpr (refl::descriptor::has_attribute<field_number_t>(member)) {
        return refl::descriptor::get_attribute<field_number_t>(member).number;
    } else {
        return static_cast<int>(index) + 1;
    }
}

template <class Descriptor>
constexpr bool field_skipped_at(Descriptor member) {
    return refl::descriptor::has_attribute<skip_t>(member) ||
        refl::descriptor::has_attribute<unknown_fields_t>(member);
}

template <class Descriptor>
void validate_field_number(Descriptor member, std::size_t index) {
    const int number = field_number_at(member, index);
    if (number < kMinFieldNumber || number > kMaxFieldNumber) {
        throw std::runtime_error("proto3: field number must be in [1, 2^29 - 1]");
    }
    if (number >= kReservedFirst && number <= kReservedLast) {
        throw std::runtime_error("proto3: field number 19000-19999 is reserved");
    }
}

template <class Descriptor, class Message>
void encode_one(std::string& out, const Message& msg, Descriptor member, std::size_t index) {
    static_assert(refl::trait::is_field_v<Descriptor>, "proto3 only serializes reflected fields");
    if constexpr (!field_skipped_at(member)) {
        validate_field_number(member, index);
        constexpr bool has_zigzag = refl::descriptor::has_attribute<zigzag_t>(member);
        constexpr bool has_fixed = refl::descriptor::has_attribute<fixed_t>(member);
        static_assert(
            !(has_zigzag && has_fixed), "proto3: zigzag and fixed are mutually exclusive"
        );
        const int number = field_number_at(member, index);
        const auto& value = member(msg);
        if constexpr (has_zigzag) {
            encode_field_zz(out, number, value);
        } else if constexpr (has_fixed) {
            encode_field_fx(out, number, value);
        } else {
            encode_field(out, number, value);
        }
    }
}

template <class Descriptor, class Message>
bool try_decode_one(
    std::string_view& in, Message& msg, int fn, wire_type wt, Descriptor member, std::size_t index
) {
    static_assert(refl::trait::is_field_v<Descriptor>, "proto3 only deserializes reflected fields");
    if constexpr (field_skipped_at(member)) {
        return false;
    } else {
        validate_field_number(member, index);
        if (fn != field_number_at(member, index)) {
            return false;
        }
        auto& value = member(msg);
        if constexpr (refl::descriptor::has_attribute<zigzag_t>(member)) {
            decode_field_zz(in, value, wt);
        } else if constexpr (refl::descriptor::has_attribute<fixed_t>(member)) {
            decode_field_fx(in, value, wt);
        } else {
            decode_field(in, value, wt);
        }
        return true;
    }
}

template <class T>
void serialize_into(std::string& out, const T& msg) {
    static_assert(
        refl::trait::is_reflectable_v<T>,
        "proto3: refl-cpp backend requires REFL_AUTO metadata for this message type"
    );
    refl::util::for_each(refl::reflect<T>().members, [&](auto member, std::size_t index) {
        encode_one(out, msg, member, index);
    });
}

template <class T>
std::string serialize(const T& msg) {
    std::string out;
    serialize_into(out, msg);
    return out;
}

template <class T>
void deserialize_from(std::string_view in, T& msg) {
    static_assert(
        refl::trait::is_reflectable_v<T>,
        "proto3: refl-cpp backend requires REFL_AUTO metadata for this message type"
    );
    while (!in.empty()) {
        std::uint64_t tag = read_varint(in);
        int fn = static_cast<int>(tag >> 3);
        wire_type wt = static_cast<wire_type>(tag & 0x7);

        bool handled = false;
        refl::util::for_each(refl::reflect<T>().members, [&](auto member, std::size_t index) {
            if (!handled) {
                handled = try_decode_one(in, msg, fn, wt, member, index);
            }
        });
        if (!handled) {
            skip_field(in, wt);
        }
    }
}

template <class T>
T deserialize(std::string_view data) {
    T msg{};
    deserialize_from(data, msg);
    return msg;
}

}  // namespace proto3

#endif  // GRPC_LITE_PROTO_USE_CPP26_META
