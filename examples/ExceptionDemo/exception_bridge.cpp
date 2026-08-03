// Odin has no C++ exception catch ABI. Keep the native throw and outer catch
// in one C++ frame so exceptions unwind through JIT code, never an Odin frame.

#include <cstdint>
#include <cstdio>
#include <stdexcept>

namespace {
    class OurCppRunException : public std::runtime_error {
    public:
        explicit OurCppRunException(char const* reason) : std::runtime_error(reason) {}
    };

    using JITFunction = void (*)(std::int32_t);
}  // namespace

extern "C" void throwCppException(std::int32_t) {
    throw OurCppRunException("thrown by throwCppException(...)");
}

extern "C" void runExceptionThrow(void* address, std::int32_t typeToThrow) {
    auto function = reinterpret_cast<JITFunction>(address);

    try {
        function(typeToThrow);
    } catch (OurCppRunException const& exception) {
        std::fprintf(stderr, "\nrunExceptionThrow(...):In C++ catch OurCppRunException "
                             "with reason: %s.\n",
                     exception.what());
    } catch (...) {
        std::fprintf(stderr, "\nrunExceptionThrow(...):In C++ catch all.\n");
    }
}
