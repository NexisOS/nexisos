project('nexisos', 'c',
  version : '0.1.0',
  license : 'GPL-3.0',
  default_options : [
    'c_std=c11',
    'warning_level=3',
    'b_lto=true',
    'b_pie=true',
  ],
)

cc = meson.get_compiler('c')

# Core defines
add_project_arguments(
  '-D_GNU_SOURCE',
  '-D_POSIX_C_SOURCE=200809L',
  language : 'c',
)

# Warnings
add_project_arguments([
  '-Wall',
  '-Wextra',
  '-Wpedantic',
  '-Wshadow',
  '-Wconversion',
], language : 'c')

# Performance (dev)
add_project_arguments('-O3', language : 'c')

# Dependencies
dep_threads = dependency('threads', required : true)

dep_lmdb    = dependency('lmdb', required : true)
dep_curl    = dependency('libcurl', required : true)

dep_seccomp = dependency('libseccomp', required : true)
dep_cap     = dependency('libcap', required : true)
dep_dbus    = dependency('dbus-1', required : true)

dep_selinux = dependency('libselinux', required : get_option('selinux'))

# BLAKE3 (vendored)
blake3_proj = subproject('blake3')
dep_blake3 = blake3_proj.get_variable('blake3_dep')

# TOML
dep_toml = dependency('toml', required : false)
if not dep_toml.found()
  dep_toml = subproject('toml-c').get_variable('toml_c_dep')
endif

# Tools
erofs_mkfs = find_program('mkfs.erofs', required : false)

# Summary
summary({
  'SELinux'      : dep_selinux.found(),
  'mkfs.erofs'   : erofs_mkfs.found(),
  'TOML parser'  : dep_toml.found() ? 'system' : 'bundled',
}, section : 'Features')

# Structure
subdir('lib')
subdir('bin')
subdir('tests')
subdir('bench')

install_subdir('modules',
  install_dir : get_option('sysconfdir') / 'nexis',
)
