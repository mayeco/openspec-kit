# frozen_string_literal: true

# ==============================================================================
# bin/lib/portal_ui.rb
#
# The operator interface of bin/portal.rb: a single-page app with one real URL per
# view (/changes, /changes/<name>/prompts/<file>, /runs/<id>, /cycles/<stamp>, ...),
# so every page has its own address, the browser's back and forward buttons work and
# a link can be shared or reloaded. The server answers every non-API path with the
# same shell; the pages live in bin/lib/portal_ui/:
#
#   shell.html          layout: sidebar, top bar, view
#   portal.css          styles
#   js/00_core.js       router, history, API client and shared components
#   js/05_actions.js    actions and rows shared by several pages
#   js/10_dashboard.js  js/20_changes.js  js/30_runs.js  js/40_observe.js
#   js/50_queue.js      js/60_system.js   js/70_recent.js   one file per group of pages
#
# The files are read on every request, so editing one needs only a reload.
# ==============================================================================

module OpenSpecPortal
  UI_DIR = File.join(__dir__, 'portal_ui')

  module_function

  def ui_shell = File.read(File.join(UI_DIR, 'shell.html'))

  def ui_css = File.read(File.join(UI_DIR, 'portal.css'))

  # Every script of js/, in name order, as one bundle.
  def ui_js
    Dir.glob(File.join(UI_DIR, 'js', '*.js')).sort.map { |f| "// #{File.basename(f)}\n#{File.read(f)}" }.join("\n;\n")
  end
end
