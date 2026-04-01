project('nexisos', 'c', 'cpp',
  version : '0.1.0',
  default_options : ['warning_level=2', 'buildtype=debugoptimized']
)

# Include all packages
subdir('packages/nexisos-core')
subdir('packages/tui-installer')

# Always build with SELinux support
add_project_arguments('-DUSE_SELINUX', language : 'c')

# ISO custom target
iso_target = custom_target(
  'nexisos-iso',
  output : get_option('iso_name'),
  command : ['bash', 'scripts/make_iso.sh'],
  build_by_default : false
)
