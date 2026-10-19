#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/cycle_prompt.rb
#
# Renders the judgment agent's prompt for one scheduled cycle: the application's
# own instructions in config/prompts/cycle.md (a seed), followed by this cycle's plan,
# which the script decides so that no model has to remember it:
#   - the exploration strategy, picked from config/exploration.yaml in
#     rotation (or at random, never one of the most recent half again). With
#     visual_qa enabled, strategies that need a browser are left to the visual
#     QA session (bin/visual_qa.sh), which picks them the same way;
#   - whether a dispatch is running, so the agent knows that it picks up what
#     it queues as soon as a worker is free;
#   - where findings go, the roadmap and how proposals get approved
#     (config/cycle.yaml);
#   - where lessons go, and which memory file is over its cap and must be
#     trimmed first (bin/lib/memory.rb);
#   - who approves a prompt proposal, an edit of config/prompts/ that the script
#     applies (bin/proposals.rb).
#
#   ruby bin/cycle_prompt.rb <output-file> [--dispatch-running PID] [--strategy SLUG]
#
# The rotation's position is kept in log/cycle/strategy_state.json.
# ==============================================================================

require 'fileutils'
require 'json'
require 'optparse'
require 'yaml'
require_relative 'lib/memory'
require_relative 'lib/prompts'

Encoding.default_external = Encoding::UTF_8

module CyclePrompt
  ROOT = File.expand_path('..', __dir__)
  CYCLE = File.join(ROOT, 'config', 'cycle.yaml')
  EXPLORATION = File.join(ROOT, 'config', 'exploration.yaml')
  STATE = File.join(ROOT, 'log', 'cycle', 'strategy_state.json')
  KINDS = {
    'defects' => 'record each confirmed defect or regression as a backlog item in `config/agent_backlog.json` ' \
                 '(openspec-kit-qa, "Record a finding"), at most %<max>d this cycle',
    'improvements' => 'record each improvement as a proposal in `config/agent_proposals.json` ' \
                      '(openspec-kit-qa, "Record a finding"), at most %<max>d this cycle',
    'features' => 'propose each missing capability as a proposal in `config/agent_proposals.json` ' \
                  '(openspec-kit-qa, "Record a finding"), at most %<max>d this cycle'
  }.freeze
  APPROVAL = {
    'jev' => 'after you exit, the script asks Jev (`config/templates/jev/proposal_review.yaml`) and queues the ' \
             'proposals it approves; the rest wait for a human',
    'human' => 'a human approves each one (`ruby bin/proposals.rb approve <change>`); the script then queues it',
    'auto' => 'the script queues every proposal after you exit, without review'
  }.freeze

  module_function

  def load_yaml(path) = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}

  # Strategies from config/exploration.yaml; an application installed before the
  # file existed still has exploration.areas in config/cycle.yaml.
  def strategies(cycle)
    list = Array(load_yaml(EXPLORATION)['strategies']).select { |s| s.is_a?(Hash) && s['slug'] && s['enabled'] != false }
    return list unless list.empty?

    Array(cycle.dig('exploration', 'areas')).map do |area|
      { 'slug' => area.to_s, 'name' => area.to_s.tr('-', ' '), 'kind' => 'defects',
        'directive' => "Explore #{area.to_s.tr('-', ' ')} for defects, missing validation and missing tests." }
    end
  end

  def visual_qa?(cycle) = cycle.dig('visual_qa', 'enabled') == true

  def needs_browser?(strategy) = strategy['needs'].to_s == 'browser'

  # The strategies this headless judgment explores: all of them, unless a visual QA
  # session takes the ones that need a browser.
  def headless(list, cycle) = visual_qa?(cycle) ? list.reject { |s| needs_browser?(s) } : list

  # Picks the next strategy and remembers it in state_file; nil when the list is empty.
  def pick(list, order, forced, state_file = STATE)
    return list.find { |s| s['slug'] == forced } || raise(ArgumentError, "unknown strategy #{forced}") if forced
    return nil if list.empty?

    FileUtils.mkdir_p(File.dirname(state_file))
    state = File.exist?(state_file) ? JSON.parse(File.read(state_file)) : {}
    slugs = list.map { |s| s['slug'] }
    chosen = if order == 'random'
               recent = Array(state['recent']) & slugs
               fresh = list.reject { |s| recent.include?(s['slug']) }
               (fresh.empty? ? list : fresh).sample
             else
               list[state['next'].to_i % list.size]
             end
    state['next'] = (slugs.index(chosen['slug']) + 1) % list.size
    state['recent'] = (Array(state['recent']) + [chosen['slug']]).last([list.size / 2, 1].max)
    File.write(state_file, "#{JSON.pretty_generate(state)}\n")
    chosen
  end

  def render(strategy, cycle, dispatch_pid)
    exploration = cycle['exploration'] || {}
    roadmap = cycle['roadmap'] || {}
    approval = cycle.dig('proposals', 'approval') || 'jev'
    strategy ||= { 'slug' => 'none', 'name' => 'None this cycle', 'kind' => 'defects',
                   'directive' => 'Every strategy of config/exploration.yaml needs a browser, so the visual QA ' \
                                  'session explores them. Spend the exploration time on the regression sweep.' }
    kind = KINDS.key?(strategy['kind']) ? strategy['kind'] : 'defects'
    max = (exploration['max_new_backlog_items_per_cycle'] || 3).to_i
    dispatch = if dispatch_pid
                 "a dispatch is running (pid #{dispatch_pid}) and builds what earlier cycles queued. Verify what " \
                 'is already integrated, explore and queue as usual: it reads the backlog again as it goes, so what ' \
                 'you queue starts as soon as a worker is free. This cycle does not count in `consecutive_failures`.'
               else
                 'none is running; the script dispatches after you exit.'
               end
    roadmap_file = roadmap['file'].to_s
    roadmap_path = File.join(ROOT, roadmap_file)
    roadmap_line = if roadmap_file.empty? || !File.file?(roadmap_path)
                     'none (`roadmap.file` in `config/cycle.yaml` is empty or missing): skip "Propose from the roadmap".'
                   elsif File.read(roadmap_path).include?('{{')
                     "`#{roadmap_file}` still has `{{...}}` placeholders: skip \"Propose from the roadmap\" and say in " \
                     'the report that a human must fill it in.'
                   else
                     "`#{roadmap_file}`: propose the next features it lists that are not built, queued or proposed yet, " \
                     "at most #{(roadmap['max_new_per_cycle'] || 1).to_i} this cycle, and none while " \
                     "#{(roadmap['max_open'] || 3).to_i} roadmap proposals are still proposed, approved or queued."
                   end
    <<~MD
      #{OpenSpecPrompts.render(ROOT, 'cycle').chomp}

      ## This cycle (decided by the script)

      - **Time**: #{(cycle['qa_time_budget_minutes'] || 45).to_i} minutes, at least #{(exploration['minutes'] || 15).to_i} of them on the exploration strategy below.
      - **Dispatch**: #{dispatch}
      - **Exploration strategy**: #{strategy['name'] || strategy['slug']} (`#{strategy['slug']}`, kind `#{kind}`).

      #{strategy['directive'].to_s.strip.gsub(/^/, '  ')}

      - **Its findings**: #{format(KINDS[kind], max: max)}. Defects found outside this strategy follow the same rule; improvements and missing capabilities always become proposals.
      - **Roadmap**: #{roadmap_line}
      - **Proposals** (`config/agent_proposals.json`, approval `#{approval}`): #{APPROVAL.fetch(approval, APPROVAL['human'])}. Add proposals with `"status": "proposed"` only; never change the status of an existing one.
      - **Visual QA**: #{visual_line(cycle)}
      - **Memory**: #{OpenSpecMemory.plan_line(ROOT)}
      - **Prompts**: #{prompts_line(cycle)}
    MD
  end

  def prompts_line(cycle)
    who = if cycle.dig('proposals', 'prompt_approval') == 'auto'
            'the script applies it after you exit, without review (`proposals.prompt_approval: auto`)'
          else
            'a human approves it (`ruby bin/proposals.rb show <change>`, then `approve <change>`), and the next cycle applies it'
          end
    'never edit `config/prompts/`; an edit of a prompt that evidence argues for is a prompt proposal ' \
      "(openspec-kit-cycle, \"Propose prompt edits\"): #{who}. Versions to compare: `ruby bin/prompt_report.rb`."
  end

  def visual_line(cycle)
    unless visual_qa?(cycle)
      return 'off (`visual_qa.enabled` in `config/cycle.yaml`): verify and explore here as well as you can.'
    end

    'a browser session in an agent app (`openspec-kit-visual-qa` skill) checks every integrated change in the ' \
      'application and explores the strategies that need a browser. You run headless: when only a browser ' \
      'can confirm something (a rendered page, a flow, the console), ask it with ' \
      '`ruby bin/visual_qa.rb request "<what to check, where, and why>" [--change <name>]` and say so in the report.'
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { dispatch: nil, strategy: nil }
  args = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/cycle_prompt.rb <output-file> [--dispatch-running PID] [--strategy SLUG]'
    opts.on('--dispatch-running PID', 'A dispatch is in progress') { |v| options[:dispatch] = v unless v.to_s.empty? }
    opts.on('--strategy SLUG', 'Use this strategy instead of the next one') { |v| options[:strategy] = v }
  end.parse(ARGV)
  abort 'Usage: ruby bin/cycle_prompt.rb <output-file> [--dispatch-running PID] [--strategy SLUG]' unless args.size == 1

  begin
    cycle = CyclePrompt.load_yaml(CyclePrompt::CYCLE)
    order = CyclePrompt.load_yaml(CyclePrompt::EXPLORATION)['order'] || 'rotation'
    strategy = CyclePrompt.pick(CyclePrompt.headless(CyclePrompt.strategies(cycle), cycle), order, options[:strategy])
    File.write(args.first, CyclePrompt.render(strategy, cycle, options[:dispatch]))
    puts "strategy: #{strategy ? "#{strategy['slug']} (#{strategy['kind'] || 'defects'})" : 'none (all need a browser)'}"
  rescue ArgumentError, Psych::Exception, JSON::ParserError => e
    warn "cycle_prompt: #{e.message}"
    exit 1
  end
end
