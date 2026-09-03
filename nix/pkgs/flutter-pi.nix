{ lib
, stdenv
, fetchFromGitHub
, cmake
, gst_all_1
, pkg-config
, libdrm
, libGL
, libgbm
, libinput
, libxkbcommon
, systemd
, udev
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "flutter-pi";
  version = "unstable-2025-06-26";

  src = fetchFromGitHub {
    owner = "ardera";
    repo = "flutter-pi";
    rev = "af8c8d66c5f40a6aaf366882bb9ca525be9c600a";
    fetchSubmodules = true;
    hash = "sha256-b+V08Kj9phtjggANEzRZfVwDYS4rYGWTjuCZgNrjLNw=";
  };

  nativeBuildInputs = [ cmake pkg-config ];
  # libgbm rather than mesa: gbm.pc moved into its own package, and mesa no
  # longer carries it -- CMake fails at "No package 'gbm' found".
  # gstreamer for the video player plugin below: core plus plugins-base, which
  # is where the app, allocators and video interfaces the plugin links against
  # live. The plugins it loads at *runtime* are a separate list, in the
  # module -- a build input here would not be on the box's plugin path.
  buildInputs = [
    gst_all_1.gst-plugins-base
    gst_all_1.gstreamer
    libdrm
    libGL
    libgbm
    libinput
    libxkbcommon
    systemd
    udev
  ];

  # The Flutter engine is not a build input: flutter-pi dlopen()s
  # libflutter_engine.so at runtime out of the app bundle, which is produced on
  # the host by flutterpi_tool.
  cmakeFlags = [
    (lib.cmakeBool "ENABLE_OPENGL" true)
    (lib.cmakeBool "TRY_ENABLE_OPENGL" false)
    (lib.cmakeBool "ENABLE_VULKAN" false)
    (lib.cmakeBool "TRY_ENABLE_VULKAN" false)
    (lib.cmakeBool "ENABLE_SOFTWARE" false)
    (lib.cmakeBool "ENABLE_SESSION_SWITCHING" false)
    (lib.cmakeBool "TRY_ENABLE_SESSION_SWITCHING" false)
    (lib.cmakeBool "BUILD_TEXT_INPUT_PLUGIN" true)
    (lib.cmakeBool "BUILD_RAW_KEYBOARD_PLUGIN" true)
    (lib.cmakeBool "BUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN" false)
    (lib.cmakeBool "TRY_BUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN" false)
    # Video. The decode is the Pi's own H.264 block through v4l2, and the
    # frames reach Flutter as dmabufs rather than being copied -- which is the
    # only reason this is possible at all on four A53 cores. Not TRY_: a build
    # that quietly dropped the plugin would leave a box whose video pages are
    # blank with nothing to say why.
    (lib.cmakeBool "BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN" true)
    (lib.cmakeBool "TRY_BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN" false)
    (lib.cmakeBool "BUILD_CHARSET_CONVERTER_PLUGIN" false)
    (lib.cmakeBool "BUILD_SENTRY_PLUGIN" false)
    (lib.cmakeBool "ENABLE_TESTS" false)
    (lib.cmakeBool "LTO" false)
  ];

  meta = {
    description = "Light-weight Flutter engine embedder rendering to KMS/DRM";
    homepage = "https://github.com/ardera/flutter-pi";
    license = lib.licenses.mit;
    mainProgram = "flutter-pi";
    platforms = lib.platforms.linux;
  };
})
