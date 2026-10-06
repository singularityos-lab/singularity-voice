project('singularity-voice', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-voice"', language: 'c')
add_project_arguments('-DVOICE_SYSCONFDIR="@0@"'.format(get_option('prefix') / get_option('sysconfdir')), language: 'c')
subdir('po')

gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
gst_dep = dependency('gstreamer-1.0')
gst_app_dep = dependency('gstreamer-app-1.0')
m_dep = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

executable('singularity-voice',
  files(
    'src/model.vala',
    'src/formats.vala',
    'src/audio.vala',
    'src/library.vala',
    'src/transcriber.vala',
    'src/waveform_view.vala',
    'src/device_picker.vala',
    'src/recording_list.vala',
    'src/window.vala',
    'src/app.vala',
    'src/gate.c',
  ),
  vala_args: ['--vapidir=' + meson.current_source_dir() / 'vapi', '--pkg=voicegate'],
  include_directories: include_directories('src'),
  dependencies: [gtk_dep, gee_dep, json_dep, gst_dep, gst_app_dep, libsingularity_dep, m_dep],
  install: true
)

model_test = executable('voice-model-test',
  files('src/model.vala', 'tests/model_test.vala'),
  dependencies: [dependency('gio-2.0'), m_dep],
)
test('voice-model', model_test)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.voice.service.in',
  output: 'dev.sinty.voice.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.voice.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.voice.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.voice.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.voice.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
