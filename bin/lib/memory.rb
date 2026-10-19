# frozen_string_literal: true

# ==============================================================================
# bin/lib/memory.rb
#
# The application's long-term memory, in two tiers:
#   MEMORY.md                      what holds for every change: every agent reads it
#   memory/repos/<name>.md         what holds for one child repository
#   memory/specs/<capability>.md   what holds for one capability of openspec/specs/
# The PLAN and BUILD prompts name the scoped files ({{memory}}), marking the ones
# of the capabilities the change modifies, so an agent opens a file only when its
# change touches that scope. Only the cycle's judgment and the visual QA session
# write them (bin/lib/record.sh). memory.max_chars and memory.scoped_max_chars of
# config/cycle.yaml cap their size, because every agent call pays for what it
# reads: the cycle's plan and the visual session's say what is over its cap, and
# the agent trims it. No script cuts a lesson.
#
#   ruby bin/lib/memory.rb status        # each file's size against its cap; exit 1 when one is over
#   ruby bin/lib/memory.rb fingerprint   # the memory's version, as agent.exit events record it
# ==============================================================================

require 'digest'
require 'yaml'

module OpenSpecMemory
  FILE = 'MEMORY.md'
  DIR = 'memory'
  DEFAULTS = { 'max_chars' => 12_000, 'scoped_max_chars' => 6000 }.freeze

  module_function

  # The caps of config/cycle.yaml; a missing, zero or unreadable one keeps its default.
  def settings(root)
    file = File.join(root, 'config', 'cycle.yaml')
    data = File.exist?(file) ? (YAML.safe_load_file(file) || {}) : {}
    given = data.is_a?(Hash) && data['memory'].is_a?(Hash) ? data['memory'] : {}
    DEFAULTS.to_h { |key, default| [key, given[key].is_a?(Integer) && given[key].positive? ? given[key] : default] }
  rescue Psych::Exception
    DEFAULTS.dup
  end

  def spec_file(capability) = "#{DIR}/specs/#{capability}.md"

  # The scoped files, relative to root, sorted.
  def scoped(root) = Dir.glob(File.join(root, DIR, '**', '*.md')).sort.map { |f| f.delete_prefix("#{root}/") }

  def files(root) = (File.file?(File.join(root, FILE)) ? [FILE] : []) + scoped(root)

  # [file, characters, cap] for every memory file.
  def sizes(root)
    caps = settings(root)
    files(root).map do |f|
      [f, File.read(File.join(root, f), encoding: 'UTF-8').length, f == FILE ? caps['max_chars'] : caps['scoped_max_chars']]
    end
  end

  def over_cap(root) = sizes(root).select { |_, chars, cap| chars > cap }

  # A short hash of every memory file, path and content: a new version whenever a lesson changes.
  def fingerprint(root)
    Digest::SHA256.hexdigest(files(root).map { |f| "#{f}\0#{File.binread(File.join(root, f))}\0" }.join)[0, 12]
  end

  # What {{memory}} says in a PLAN or BUILD prompt: the scoped files, those of the
  # capabilities the change modifies first. Empty while memory/ holds none.
  def prompt_block(root, capabilities: [])
    files = scoped(root)
    return '' if files.empty?

    own = capabilities.map { |c| spec_file(c) } & files
    repos = files.select { |f| f.start_with?("#{DIR}/repos/") }
    specs = files.select { |f| f.start_with?("#{DIR}/specs/") } - own
    other = files - own - repos - specs
    lines = ["\nLessons that hold for one repository or one capability are in #{DIR}/:"]
    lines << "- read these before you start, for the capabilities this change modifies: #{own.join(', ')}" if own.any?
    lines << "- open the ones of the repositories you change: #{repos.join(', ')}" if repos.any?
    lines << "- open the ones of any other capability your change touches: #{specs.join(', ')}" if specs.any?
    lines << "- also: #{other.join(', ')}" if other.any?
    lines.join("\n")
  end

  # One line for the cycle's plan and the visual session's: where lessons go, and what to trim first.
  def plan_line(root)
    caps = settings(root)
    main = sizes(root).find { |f, *| f == FILE }
    line = "`#{FILE}` (#{main ? main[1] : 0} of #{caps['max_chars']} characters) for what holds for every change; " \
           "`#{DIR}/repos/<name>.md` and `#{DIR}/specs/<capability>.md` (#{caps['scoped_max_chars']} each) for what holds " \
           'for one repository or capability, read only by the changes that touch it.'
    over = over_cap(root)
    return line if over.empty?

    "#{line} Over the cap, trim first: #{over.map { |f, chars, cap| "`#{f}` (#{chars} of #{cap})" }.join(', ')}. " \
      'Move what holds for one scope into its file, merge duplicates, and drop what no longer holds or is never acted on.'
  end
end

if __FILE__ == $PROGRAM_NAME
  root = File.expand_path('../..', __dir__)
  case ARGV
  in ['status']
    OpenSpecMemory.sizes(root).each do |file, chars, cap|
      puts format('%-48<file>s %7<chars>d of %<cap>d%<over>s', file: file, chars: chars, cap: cap, over: chars > cap ? '  OVER' : '')
    end
    exit(OpenSpecMemory.over_cap(root).empty? ? 0 : 1)
  in ['fingerprint']
    puts OpenSpecMemory.fingerprint(root)
  else
    warn 'Usage: ruby bin/lib/memory.rb status | fingerprint'
    exit 2
  end
end
