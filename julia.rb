class GitNoDepthDownloadStrategy < GitDownloadStrategy
  # We need the .git folder for its information, so we clone the whole thing
  def stage
    dst = Dir.getwd
    @clone.cd do
      reset
      safe_system "git", "clone", ".", dst
    end
  end
end

class Julia < Formula
  homepage "http://julialang.org"

  stable do
    url "https://github.com/JuliaLang/julia.git",
      :using => GitNoDepthDownloadStrategy, :shallow => false, :tag => "v0.5.2"
  end

  head do
    url "https://github.com/JuliaLang/julia.git",
      :using => GitNoDepthDownloadStrategy, :shallow => false
  end

  depends_on "dpo/julia/llvm37-julia"
  depends_on "pcre2"
  depends_on "gmp"
  depends_on "fftw"
  depends_on :fortran
  depends_on "mpfr"
  depends_on "libgit2"
  depends_on "mbedtls"
  depends_on "cmake" => :build

  # We have our custom formulae of arpack, openblas and suite-sparse
  depends_on "arpack"
  depends_on "openblas"
  depends_on "suite-sparse"

  # Need this as Julia"s build process is quite messy with respect to env variables
  env :std

  # Options that can be passed to the build process
  option "system-libm", "Use system's libm instead of openlibm"

  def install
    ENV["PLATFORM"] = "darwin"
    ENV["PYTHONPATH"] = ""

    # Build up list of build options
    build_opts = ["prefix=#{prefix}"]
    build_opts << "USE_BLAS64=0"
    build_opts << "TAGGED_RELEASE_BANNER=\"homebrew-julia release\""

    # Tell julia about our gfortran
    build_opts << "FC=#{ENV["FC"]}" if ENV.key? "FC"

    # Tell julia about our llvm-config, since it"s been named nonstandardly
    build_opts << "LLVM_CONFIG=llvm-config-3.7"
    build_opts << "LLVM_VER=3.7.1"
    ENV["CPPFLAGS"] += " -DUSE_ORCJIT "

    # Tell julia where the default software base is, mostly for suitesparse
    build_opts << "LOCALBASE=#{prefix}"

    # Make sure we have space to muck around with RPATHS
    ENV["LDFLAGS"] += " -headerpad_max_install_names"

    # Make sure Julia uses clang if the environment supports it
    build_opts << "USECLANG=1" if ENV.compiler == :clang
    build_opts << "VERBOSE=1" if ARGV.verbose?

    build_opts << "LIBBLAS=-lopenblas"
    build_opts << "LIBBLASNAME=libopenblas"
    build_opts << "LIBLAPACK=-lopenblas"
    build_opts << "LIBLAPACKNAME=libopenblas"

    # Kudos to @ijt for these lines of code
    %w[FFTW GLPK GMP LLVM PCRE BLAS LAPACK SUITESPARSE ARPACK MPFR LIBGIT2].each do |dep|
      build_opts << "USE_SYSTEM_#{dep}=1"
    end

    build_opts << "USE_SYSTEM_LIBM=1" if build.include? "system-libm"

    # If we"re building a bottle, cut back on fancy CPU instructions
    build_opts << "MARCH=core2" if build.bottle?

    # Sneak in the fftw libraries, as julia doesn"t know how to load dylibs from any place other than
    # julia"s usr/lib directory and system default paths yet; the build process fixes that after the
    # install step, but the bootstrapping process requires the use of the fftw libraries before then
    mkdir_p "usr/lib"
    # ["", "f", "_threads", "f_threads"].each do |ext|
    #   ln_s "#{Formula["fftw"].lib}/libfftw3#{ext}.dylib", "usr/lib/"
    # end
    # Do the same for openblas, pcre, mpfr, and gmp
    ln_s "#{Formula["openblas"].opt_lib}/libopenblas.dylib", "usr/lib/"
    ln_s "#{Formula["arpack"].opt_lib}/libarpack.dylib", "usr/lib/"
    ln_s "#{Formula["pcre2"].lib}/libpcre2-8.dylib", "usr/lib/"
    ln_s "#{Formula["mpfr"].lib}/libmpfr.dylib", "usr/lib/"
    ln_s "#{Formula["gmp"].lib}/libgmp.dylib", "usr/lib/"
    ln_s "#{Formula["libgit2"].lib}/libgit2.dylib", "usr/lib/"

    system "make", "release", "debug", *build_opts
    system "make", "install", *build_opts
  end

  def post_install
    # We add in some custom RPATHs to julia
    rpaths = []

    # Add in each key-only formula to the rpaths list
    ["arpack", "suite-sparse", "openblas"].each do |formula|
      rpaths << Formula[formula].opt_lib.to_s
    end

    # Add in generic Homebrew and system paths, as it might not be standard system paths
    rpaths << "#{HOMEBREW_PREFIX}/lib"

    # Only add this in if we"re < 10.8, because after that libxstub makes our lives miserable
    rpaths << "/usr/X11/lib" if MacOS.version < :mountain_lion

    # Add those rpaths to the binaries
    rpaths.each do |rpath|
      Dir["#{bin}/julia*"].each do |file|
        chmod 0755, file
        quiet_system "install_name_tool", "-add_rpath", rpath, file
        chmod 0555, file
      end
    end

    # Change the permissions of lib/julia/sys.{dylib,ji} so that build_sysimg.jl can edit them
    Dir["#{lib}/julia/sys*.{dylib,ji}"].each do |file|
      chmod 0644, file
    end
  end

  test do
    # Run julia-provided test suite, copied over in install step
    if !(share/"julia/test").exist?
      err = "Could not find test files directory\n"
      if build.head?
        err << "Did you accidentally include --HEAD in the test invocation?"
      else
        err << "Did you mean to include --HEAD in the test invocation?"
      end
      opoo err
    else
      system "#{bin}/julia", "-e", "Base.runtests(\"core\")"
    end
  end

  def caveats
    head_flag = build.head? ? " --HEAD " : " "
    <<-EOS.undent
      Documentation and Examples have been installed into:
      #{share}/julia

      Test suite has been installed into:
      #{share}/julia/test

      To perform a quick sanity check, run the command:
      brew test#{head_flag}-v julia

      To crunch through the full test suite, run the command:
      #{bin}/julia -e "Base.runtests()"
    EOS
  end
end
