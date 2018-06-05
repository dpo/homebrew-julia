class CodesignRequirement < Requirement
  include FileUtils
  fatal true

  satisfy(:build_env => false) do
    mktemp do
      cp "/usr/bin/false", "llvm_check"
      quiet_system "/usr/bin/codesign", "-f", "-s", "lldb_codesign", "--dryrun", "llvm_check"
    end
  end

  def message
    <<~EOS
      lldb_codesign identity must be available to build with LLDB.
      See: https://llvm.org/svn/llvm-project/lldb/trunk/docs/code-signing.txt
    EOS
  end
end

class Llvm39Julia < Formula
  desc "Next-gen compiler infrastructure"
  homepage "https://llvm.org/"
  revision 1

  stable do
    url "https://llvm.org/releases/3.9.1/llvm-3.9.1.src.tar.xz"
    sha256 "1fd90354b9cf19232e8f168faf2220e79be555df3aa743242700879e8fd329ee"

    # Only required to build & run Compiler-RT tests on macOS, optional otherwise.
    # http://clang.llvm.org/get_started.html
    resource "libcxx" do
      url "https://llvm.org/releases/3.9.1/libcxx-3.9.1.src.tar.xz"
      sha256 "25e615e428f60e651ed09ffd79e563864e3f4bc69a9e93ee41505c419d1a7461"
    end

    resource "libunwind" do
      url "https://llvm.org/releases/3.9.1/libunwind-3.9.1.src.tar.xz"
      sha256 "0b0bc73264d7ab77d384f8a7498729e3c4da8ffee00e1c85ad02a2f85e91f0e6"
    end
  end

  head do
    url "https://llvm.org/git/llvm.git"

    resource "libcxx" do
      url "https://llvm.org/git/libcxx.git"
    end

    resource "libunwind" do
      url "https://llvm.org/git/libunwind.git"
    end
  end

  def patches
    patch_list = []
    ["PR22923",
     "arm-fix-prel31",
     "D25865-cmakeshlib",
     "3.9.0_threads",
     "3.9.0_win64-reloc-dwarf",
     "3.9.0_D27296-libssp",
     "D27609-AArch64-UABS_G3",
     "D27629-AArch64-large_model",
     "D9168_argument_alignment",
     "D23597_sdag_names",
     "D24300_ptx_intrinsics",
     "D27389",
     "D27397",
     "D28009",
     "D28215_FreeBSD_shlib",
     "D28221-avx512",
     "PR276266",
     "PR278088",
     "PR277939",
     "PR278321",
     "PR278923",
     "D28759-loopclearance",
     "D28786-callclearance",
     "rL293230-icc17-cmake",
     "D32593",
     "D33179",
     "PR29010-i386-xmm",
     "3.9.0-D37576-NVPTX-sm_70",
     "D31524-sovers_4.0"].each do |patch_name|
      patch_list << "https://raw.githubusercontent.com/JuliaLang/julia/v0.6.3/deps/patches/llvm-#{patch_name}.patch"
    end
    patch_list
  end

  keg_only :provided_by_macos

  option "without-compiler-rt", "Do not build Clang runtime support libraries for code sanitizers, builtins, and profiling"
  option "without-libcxx", "Do not build libc++ standard library"
  option "with-toolchain", "Build with Toolchain to facilitate overriding system compiler"
  option "with-lldb", "Build LLDB debugger"
  option "with-shared-libs", "Build shared instead of static libraries"
  option "without-libffi", "Do not use libffi to call external functions"
  option "with-all-targets", "Build all targets. Default targets: AMDGPU, ARM, NVPTX, and X86"

  depends_on "python@2" unless OS.mac?
  depends_on "libffi" => :recommended # https://llvm.org/docs/GettingStarted.html#requirement
  depends_on "graphviz" => :optional # for the 'dot' tool (lldb)

  depends_on "ocaml" => :optional
  if build.with? "ocaml"
    depends_on "opam" => :build
    depends_on "pkg-config" => :build
  end

  depends_on "cmake" => :build

  if build.with? "lldb"
    depends_on "swig" if MacOS.version >= :lion
    depends_on CodesignRequirement
  end

  # According to the official llvm readme, GCC 4.7+ is required
  fails_with :gcc_4_0
  fails_with :gcc
  ("4.3".."4.6").each do |n|
    fails_with :gcc => n
  end

  def build_libcxx?
    build.with?("libcxx") || !MacOS::CLT.installed?
  end

  def install
    # Apple's libstdc++ is too old to build LLVM
    ENV.libcxx if ENV.compiler == :clang

    (buildpath/"projects/libcxx").install resource("libcxx") if build_libcxx?
    (buildpath/"projects/libunwind").install resource("libunwind")

    if build.with? "lldb"
      pyhome = `python-config --prefix`.chomp
      ENV["PYTHONHOME"] = pyhome
      pylib = "#{pyhome}/lib/libpython2.7.dylib"
      pyinclude = "#{pyhome}/include/python2.7"
      (buildpath/"tools/lldb").install resource("lldb")

      # Building lldb requires a code signing certificate.
      # The instructions provided by llvm creates this certificate in the
      # user's login keychain. Unfortunately, the login keychain is not in
      # the search path in a superenv build. The following three lines add
      # the login keychain to ~/Library/Preferences/com.apple.security.plist,
      # which adds it to the superenv keychain search path.
      mkdir_p "#{ENV["HOME"]}/Library/Preferences"
      username = ENV["USER"]
      system "security", "list-keychains", "-d", "user", "-s", "/Users/#{username}/Library/Keychains/login.keychain"
    end

    args = %w[
      -DLLVM_OPTIMIZED_TABLEGEN=ON
      -DLLVM_INCLUDE_DOCS=OFF
      -DLLVM_ENABLE_RTTI=ON
      -DLLVM_ENABLE_EH=ON
      -DLLVM_INSTALL_UTILS=ON
    ]
    args << "-DLLVM_TARGETS_TO_BUILD=#{build.with?("all-targets") ? "all" : "AMDGPU;ARM;NVPTX;X86"}"
    args << "-DLIBOMP_ARCH=x86_64"
    args << "-DLLVM_CREATE_XCODE_TOOLCHAIN=ON" if build.with? "toolchain"

    if build.with? "shared-libs"
      args << "-DBUILD_SHARED_LIBS=ON"
      args << "-DLIBOMP_ENABLE_SHARED=ON"
    else
      args << "-DLLVM_BUILD_LLVM_DYLIB=ON"
    end

    args << "-DLLVM_ENABLE_LIBCXX=ON" if build_libcxx?

    if build.with?("lldb")
      args << "-DLLDB_RELOCATABLE_PYTHON=ON"
      args << "-DPYTHON_LIBRARY=#{pylib}"
      args << "-DPYTHON_INCLUDE_DIR=#{pyinclude}"
    end

    if build.with? "libffi"
      args << "-DLLVM_ENABLE_FFI=ON"
      args << "-DFFI_INCLUDE_DIR=#{Formula["libffi"].opt_lib}/libffi-#{Formula["libffi"].version}/include"
      args << "-DFFI_LIBRARY_DIR=#{Formula["libffi"].opt_lib}"
    end

    mktemp do
      if build.with? "ocaml"
        ENV["OPAMYES"] = "1"
        ENV["OPAMROOT"] = Pathname.pwd/"opamroot"
        (Pathname.pwd/"opamroot").mkpath
        system "opam", "init", "--no-setup"
        system "opam", "install", "ocamlfind", "ctypes"
        system "opam", "config", "exec", "--",
               "cmake", "-G", "Unix Makefiles", buildpath, *(std_cmake_args + args)
      else
        system "cmake", "-G", "Unix Makefiles", buildpath, *(std_cmake_args + args)
      end
      system "make"
      system "make", "install"
      system "make", "install-xcode-toolchain" if build.with? "toolchain"
    end

    # install llvm python bindings
    (lib/"python2.7/site-packages").install buildpath/"bindings/python/llvm"
  end

  def caveats
    s = <<~EOS
      LLVM executables are installed in #{opt_bin}.
      Extra tools are installed in #{opt_pkgshare}.
    EOS

    if build_libcxx?
      s += <<~EOS
        To use the bundled libc++ please add the following LDFLAGS:
          LDFLAGS="-L#{opt_lib} -Wl,-rpath,#{opt_lib}"
      EOS
    end

    s
  end

  test do
    assert_equal prefix.to_s, shell_output("#{bin}/llvm-config --prefix").chomp
  end
end
