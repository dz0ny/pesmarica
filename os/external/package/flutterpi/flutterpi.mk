################################################################################
#
# flutterpi
#
# flutter-pi, built WITHOUT buildroot's flutter-engine package. The engine
# (libflutter_engine.so + icudtl.dat + app.so) is dlopen'ed at runtime from the
# app bundle in /opt/pesmarica/bundle, which is produced on the macOS host by
# flutterpi_tool. Building the engine from source here would cost hours and
# tens of GB for a binary Google already publishes.
#
# Bump FLUTTERPI_VERSION together with the pinned Flutter SDK in
# scripts/build-bundle.sh: the embedder ABI is versioned.
#
################################################################################

FLUTTERPI_VERSION = af8c8d66c5f40a6aaf366882bb9ca525be9c600a
FLUTTERPI_SITE = https://github.com/ardera/flutter-pi.git
FLUTTERPI_SITE_METHOD = git
FLUTTERPI_GIT_SUBMODULES = YES
FLUTTERPI_LICENSE = MIT
FLUTTERPI_LICENSE_FILES = LICENSE

FLUTTERPI_DEPENDENCIES = \
	host-pkgconf \
	libdrm \
	libinput \
	libxkbcommon \
	libgles \
	libegl \
	libgbm \
	systemd

# Everything optional is off: this is a signage appliance, not a demo board.
FLUTTERPI_CONF_OPTS = \
	-DCMAKE_BUILD_TYPE=Release \
	-DENABLE_OPENGL=ON \
	-DTRY_ENABLE_OPENGL=OFF \
	-DENABLE_VULKAN=OFF \
	-DTRY_ENABLE_VULKAN=OFF \
	-DENABLE_SOFTWARE=OFF \
	-DENABLE_SESSION_SWITCHING=OFF \
	-DTRY_ENABLE_SESSION_SWITCHING=OFF \
	-DBUILD_TEXT_INPUT_PLUGIN=ON \
	-DBUILD_RAW_KEYBOARD_PLUGIN=ON \
	-DBUILD_TEST_PLUGIN=OFF \
	-DBUILD_CHARSET_CONVERTER_PLUGIN=OFF \
	-DBUILD_SENTRY_PLUGIN=OFF \
	-DBUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF \
	-DTRY_BUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF \
	-DBUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=OFF \
	-DTRY_BUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=OFF \
	-DENABLE_TESTS=OFF \
	-DENABLE_ASAN=OFF \
	-DENABLE_TSAN=OFF \
	-DENABLE_UBSAN=OFF \
	-DENABLE_MTRACE=OFF \
	-DUSE_LEGACY_KMS=OFF \
	-DLINT_EGL_HEADERS=OFF \
	-DDUMP_ENGINE_LAYERS=OFF \
	-DDEBUG_DRM_PLANE_ALLOCATIONS=OFF \
	-DWARN_MISSING_FIELD_INITIALIZERS=OFF \
	-DLTO=OFF

$(eval $(cmake-package))
