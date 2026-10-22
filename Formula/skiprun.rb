# Drop this file into a tap repository (github.com/<user>/homebrew-tap) as
# Formula/skiprun.rb; install with `brew install <user>/tap/skiprun`.
# `brew install --HEAD <user>/tap/skiprun` works before the first tag; for a tagged
# release fill `sha256` with `shasum -a 256` of the tarball at `url`.
class Skiprun < Formula
  desc "Build, install and launch a Skip app on the iOS simulator, the Android emulator or a phone"
  homepage "https://github.com/janpodmolik/skiprun"
  url "https://github.com/janpodmolik/skiprun/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/janpodmolik/skiprun.git", branch: "main"

  depends_on :macos
  depends_on "skip"
  depends_on "fzf" => :recommended

  def install
    libexec.install "bin", "lib", "libexec"
    bin.install_symlink libexec/"bin/skiprun"
  end

  test do
    assert_match(/^skiprun \d+\.\d+\.\d+$/, shell_output("#{bin}/skiprun --version"))
    assert_match "Usage: skiprun ios", shell_output("#{bin}/skiprun ios --help")
  end
end
