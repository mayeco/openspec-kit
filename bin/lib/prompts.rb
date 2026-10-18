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
#
#   ruby bin/lib/prompts.rb check                  # problems of every prompt; exit 1 on one
#   ruby bin/lib/prompts.rb render plan k=v ...    # a prompt as an agent would get it
# ==============================================================================

module OpenSpecPrompts
  DIR = 'config/prompts'
  # prompt => { placeholder => what the script puts there }
  PLACEHOLDERS = {
    'plan' => {
      'change' => "the change's name",
      'goal' => "the backlog item's description",
      'jev_hint' => 'how to ask Jev a yes/no question (empty without Jev)',
      'authoring_rules' => "the kit's rules for OpenSpec artifacts (config/templates/authoring_rules.md)",
      'feedback' => 'on a repair round, exactly what failed verification (empty on the first attempt)'
    },
    'build' => {
      'change' => "the change's name",
      'branch' => 'the feature branch every child repository is on',
      'jev_hint' => 'how to ask Jev a yes/no question (empty without Jev)',
      'authoring_rules' => "the kit's rules for OpenSpec artifacts (config/templates/authoring_rules.md)",
      'feedback' => 'on a repair round, exactly what failed verification (empty on the first attempt)',
      'rebuild' => 'when the change is rebuilt after a rebase conflict, where the old code is (empty otherwise)'
    },
    # bin/cycle_prompt.rb appends "This cycle" (strategy, dispatch, roadmap, approval) after it.
    'cycle' => {}
  }.freeze
  # Without these a prompt cannot work: a repair round would never see what failed.
  REQUIRED = { 'plan' => %w[change feedback], 'build' => %w[change branch feedback rebuild], 'cycle' => [] }.freeze
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
  in ['render', name, *pairs]
    begin
      print OpenSpecPrompts.render(root, name, pairs.to_h { |pair| pair.split('=', 2) })
    rescue OpenSpecPrompts::Error => e
      warn "prompts: #{e.message}"
      exit 1
    end
  else
    warn 'Usage: ruby bin/lib/prompts.rb check | render <plan|build|cycle> [name=value ...]'
    exit 2
  end
end
