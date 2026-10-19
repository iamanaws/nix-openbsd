// Run the interpreter's roundeven regression with each host rounding mode.
#include <cfenv>
#include <cstdio>
#include <llvm/AsmParser/Parser.h>
#include <llvm/ExecutionEngine/GenericValue.h>
#include <llvm/ExecutionEngine/Interpreter.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/Support/SourceMgr.h>
#include <llvm/Support/raw_ostream.h>
#include <memory>
#include <string>
#include <utility>

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "Usage: %s roundeven.ll\n", argv[0]);
    return 1;
  }

  const int original = std::fegetround();
  const int modes[] = {FE_TONEAREST, FE_UPWARD, FE_DOWNWARD, FE_TOWARDZERO};
  for (const int mode : modes) {
    llvm::LLVMContext context;
    llvm::SMDiagnostic diagnostic;
    auto module = llvm::parseAssemblyFile(argv[1], diagnostic, context);
    if (!module) {
      diagnostic.print(argv[0], llvm::errs());
      return 1;
    }
    auto *main = module->getFunction("main");
    if (!main) {
      std::fputs("Missing main function in the IR test\n", stderr);
      return 1;
    }
    std::string error;
    std::unique_ptr<llvm::ExecutionEngine> interpreter(
        llvm::EngineBuilder(std::move(module))
            .setEngineKind(llvm::EngineKind::Interpreter)
            .setErrorStr(&error)
            .create());
    if (!interpreter) {
      std::fprintf(stderr, "Cannot create interpreter: %s\n", error.c_str());
      return 1;
    }
    if (std::fesetround(mode) != 0) {
      std::fputs("Cannot set host rounding mode\n", stderr);
      return 1;
    }
    const auto result = interpreter->runFunction(main, {});
    if (result.IntVal != 0 || std::fegetround() != mode) {
      std::fprintf(stderr,
                   "roundeven failed or changed host rounding mode %d\n", mode);
      return 1;
    }
    std::printf("PASS roundeven host rounding mode %d\n", mode);
  }
  if (std::fesetround(original) != 0)
    return 1;
  std::puts("LLVM_ROUNDEVEN_PASS");
}
