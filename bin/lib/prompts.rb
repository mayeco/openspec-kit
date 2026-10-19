# frozen_string_literal: true

# ==============================================================================
# bin/lib/prompts.rb
#
# The agents' prompts belong to the application: config/prompts/plan.md (the
# PLAN agent), build.md (the BUILD agent) and cycle.md (the scheduled cycle's
# judgment). The kit creates them once from its seeds and never replaces them; an
# upgrade whose template changed writes <file>.new beside them. A prompt is
# Markdown with {{name}} placeholders that the scripts fill. HTML comments
# (<!-- ... -->) are notes for whoever edits the prompt and never reach the agent.
# Every PLAN and BUILD call records its prompt's version in its agent.exit
# event, so bin/prompt_report.rb can tell how each version did.
#
#   ruby bin/lib/prompts.rb check                  # problems of every prompt; exit 1 on one
#   ruby bin/lib/prompts.rb render plan k=v ...    # a prompt as an agent would get it
#   ruby bin/lib/prompts.rb version plan           # the version agent.exit events record
# ==============================================================================

require 'digest'

module OpenSpecPrompts
  DIR = 'config/prompts'
  # prompt => { placeholder => what the script puts there }
  PLACEHOLDERS = {
    'plan' => {
      'change' => "the change's name",
      'goal' => "the backlog item's description",
      'memory' => 'the lesson files of memory/ (bin/lib/memory.rb), those of the capabilities the change modifies first (empty while there are none)',
      'jev_hint' => 'how to ask Jev a yes/no question (empty without Jev)',
      'authoring_rules' => "the kit's rules for OpenSpec artifacts (config/templates/authoring_rules.md)",
      'feedback' => 'on a repair round, exactly what failed verification; on the first call after an automatic retry, also what quarantined the change (empty on the first attempt)'
    },
    'build' => {
      'change' => "the change's name",
      'branch' => 'the feature branch every child repository is on',
      'memory' => 'the lesson files of memory/ (bin/lib/memory.rb), those of the capabilities the change modifies first (empty while there are none)',
      'jev_hint' => 'how to ask Jev a yes/no question (empty without Jev)',
      'authoring_rules' => "the kit's rules for OpenSpec artifacts (config/templates/authoring_rules.md)",
      'feedback' => 'on a repair round, exactly what failed verification; on the first call after an automatic retry, also what quarantined the change (empty on the first attempt)',
      'rebuild' => 'when the change is rebuilt after a rebase conflict, where the old code is (empty otherwise)'
    },
    # bin/cycle_prompt.rb appends "This cycle" (strategy, dispatch, roadmap, approval) after it.
    'cycle' => {}
  }.freeze
  # Without these a prompt cannot work: a repair round would never see what failed.
  REQUIRED = { 'plan' => %w[change feedback], 'build' => %w[change branch feedback rebuild], 'cycle' => [] }.freeze
  # The kit's rules for OpenSpec artifacts, which fill {{authoring_rules}}.
  RULES = 'config/templates/authoring_rules.md'
  COMMENT = /<!--.*?-->\n?/m
  PLACEHOLDER = /\{\{(\w+)\}\}/

  class Error < StandardError; end

  module_function

  def path(root, name) = File.join(root, DIR, "#{name}.md")

  # The prompt as the agent gets it: comments dropped, placeholders filled. One the
  # script does not know is left as written (`check` reports it).
  def render(root, name, vars = {})
    file = path(root, name)
    raise Error, "#{DIR}/#{name}.md is missing: restore it from the kit's release (a seed), then commit it" unless File.file?(file)

    File.read(file, encoding: 'UTF-8').gsub(COMMENT, '').gsub(PLACEHOLDER) do
      vars.key?(Regexp.last_match(1)) ? vars[Regexp.last_match(1)].to_s : Regexp.last_match(0)
    end
  end

  # The version of a prompt, as agent.exit events record it: a short hash of what its
  # agent reads on every call, the prompt without its notes (editing a note makes no
  # new version) and the kit's authoring rules when it carries them.
  def version(root, name)
    parts = [File.read(path(root, name), encoding: 'UTF-8').gsub(COMMENT, '')]
    rules = File.join(root, RULES)
    parts << File.read(rules, encoding: 'UTF-8') if placeholders(root, name).include?('authoring_rules') && File.file?(rules)
    Digest::SHA256.hexdigest(parts.join("\0"))[0, 12]
  end

  def placeholders(root, name) = File.read(path(root, name), encoding: 'UTF-8').gsub(COMMENT, '').scan(PLACEHOLDER).flatten.uniq

  # { errors: [...], warnings: [...] } for every prompt.
  def problems(root)
    report = { errors: [], warnings: [] }
    PLACEHOLDERS.each do |name, known|
      rel = "#{DIR}/#{name}.md"
      next report[:errors] << "#{rel} is missing: restore it from the kit's release (a seed)" unless File.file?(path(root, name))

      used = placeholders(root, name)
      (used - known.keys).each do |p|
        report[:errors] << "#{rel}: unknown placeholder {{#{p}}}#{known.empty? ? ' (it takes none)' : " (known: #{known.keys.join(', ')})"}"
      end
      (REQUIRED.fetch(name) - used).each { |p| report[:errors] << "#{rel}: {{#{p}}} is missing: #{known[p]}" }
    end
    report
  end
end

if __FILE__ == $PROGRAM_NAME
  root = File.expand_path('../..', __dir__)
  case ARGV
  in ['check']
    report = OpenSpecPrompts.problems(root)
    report[:errors].each { |e| puts "ERROR #{e}" }
    puts report[:errors].empty? ? 'prompts: OK' : "prompts: FAIL (#{report[:errors].size})"
    exit(report[:errors].empty? ? 0 : 1)
  in ['version', name]
    abort "prompts: #{OpenSpecPrompts::DIR}/#{name}.md is missing" unless File.file?(OpenSpecPrompts.path(root, name))
    puts OpenSpecPrompts.version(root, name)
  in ['render', name, *pairs]
    begin
      print OpenSpecPrompts.render(root, name, pairs.to_h { |pair| pair.split('=', 2) })
    rescue OpenSpecPrompts::Error => e
      warn "prompts: #{e.message}"
      exit 1
    end
  else
    warn 'Usage: ruby bin/lib/prompts.rb check | render <plan|build|cycle> [name=value ...] | version <plan|build|cycle>'
    exit 2
  end
end
