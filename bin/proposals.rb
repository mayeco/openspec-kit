#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/proposals.rb
#
# Proposals are work the scheduled cycle suggests but does not queue itself:
# improvements and missing capabilities it found while exploring, the next
# features of the roadmap, and edits of the agents' prompts. The judgment agent
# adds them to config/agent_proposals.json with status "proposed"; this script
# decides, deterministically, what reaches config/agent_backlog.json, and applies
# the prompt edits.
#
#   ruby bin/proposals.rb review           # run by run_cycle.sh after the judgment
#   ruby bin/proposals.rb rebase <base>    # record.sh: the record commit onto origin/<base>, reconciled
#   ruby bin/proposals.rb carry <checkout> # the checkout's uncommitted scope edits merged into this worktree
#   ruby bin/proposals.rb list
#   ruby bin/proposals.rb show <change>     # one proposal; a prompt edit as a diff
#   ruby bin/proposals.rb approve <change>  # a human approves; the next review queues or applies it
#   ruby bin/proposals.rb reject <change>
#
# review applies `proposals.approval` of config/cycle.yaml to each proposal still
# "proposed":
#   jev    Jev answers config/templates/jev/proposal_review.yaml (gate proposal_review of
#          config/jev_policy.yaml). In enforce mode a passing proposal is approved;
#          otherwise, or with Jev off or unavailable, the answers are recorded and it
#          waits for a human. Jev is asked once per proposal: delete its "review"
#          to ask again.
#   human  it waits for `approve` or `reject`.
#   auto   it is approved at once.
# Every approved proposal is then appended to the backlog ("queued"), a queued
# one whose change was archived becomes "integrated", and any archived item in
# config/agent_backlog.json moves to config/agent_history.json.
#
# A prompt proposal ("kind": "prompt") edits config/prompts/<prompt>.md (plan,
# build or cycle) instead: a list of "edits", each an "old" text that must occur
# exactly once and its "new" replacement, with the "evidence" that argues for it.
# `proposals.prompt_approval` decides who approves it: human (the default) or
# auto. Once approved, review applies the edits, checks the prompt
# (bin/lib/prompts.rb) and marks it "integrated" with the prompt's version before
# and after, which bin/prompt_report.rb then compares; the record step commits the
# prompt. An edit that no longer matches, or a prompt that fails its check, leaves
# the file as it was and the proposal "rejected" with the reason in review.apply_error.
# The judgment never writes a prompt itself: the scope guard runs before review.
# ==============================================================================

require 'json'
require 'time'
require 'yaml'
require_relative 'lib/openspec_orchestrator'
require_relative 'lib/prompts'

module Proposals
  O = OpenSpecOrchestrator
  FILE = File.join(O::ROOT, 'config', 'agent_proposals.json')
  CYCLE = File.join(O::ROOT, 'config', 'cycle.yaml')
  # Proposal-only fields: everything else is copied into the backlog item.
  OWN_FIELDS = %w[status source strategy proposed_at review queued_at integrated_at].freeze
  OPEN = %w[proposed approved queued].freeze
  PROMPT_APPROVALS = %w[human auto].freeze

  # A prompt proposal that cannot be applied as it stands.
  class ApplyError < StandardError; end

  module_function

  def read(path)
    data = File.exist?(path) ? JSON.parse(File.read(path)) : []
    data.is_a?(Hash) ? Array(data['changes']) : Array(data)
  end

  def write(path, items)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, "#{JSON.pretty_generate(items)}\n")
    File.rename(tmp, path)
  end

  def settings = File.exist?(CYCLE) ? (YAML.safe_load_file(CYCLE) || {}) : {}

  def approval = settings.dig('proposals', 'approval') || 'jev'

  # Who approves a prompt proposal; anything but auto means a human.
  def prompt_approval = settings.dig('proposals', 'prompt_approval') == 'auto' ? 'auto' : 'human'

  def prompt?(item) = item['kind'] == 'prompt'

  def now = Time.now.utc.iso8601

  # Exactly <date>-<name>: a glob on *-<name> took add-mfa's archive for mfa's.
  def archived?(name) = O.archived_changes.include?(name)

  # What Jev needs to judge a proposal: the proposal, the roadmap, and what is
  # already specified, queued or proposed, so that a duplicate is recognizable.
  def jev_state(item, items, backlog)
    roadmap = (File.exist?(CYCLE) && YAML.safe_load_file(CYCLE)&.dig('roadmap', 'file')).to_s
    roadmap_path = File.join(O::ROOT, roadmap)
    specs = O.run(%w[openspec list --specs --json], timeout: 120, stderr: :separate)
    capabilities = begin
      Array(JSON.parse(specs.out)['specs']).map { |s| s['id'] || s['name'] }.compact
    rescue JSON::ParserError, TypeError
      []
    end
    {
      'proposal' => item.reject { |k, _| OWN_FIELDS.include?(k) && k != 'source' },
      'roadmap' => !roadmap.empty? && File.file?(roadmap_path) ? File.read(roadmap_path) : '',
      'existing_capabilities' => capabilities,
      'queued_changes' => backlog.map { |b| b['change_name'] },
      'other_proposals' => items.reject { |p| p.equal?(item) }.map { |p| "#{p['change_name']} (#{p['status']})" }
    }
  end

  def ask_jev(item, items, backlog)
    verdict = O::Jev.ask('proposal_review', jev_state(item, items, backlog),
                         cache_dir: File.join(O::LOG_DIR, 'cycle', 'jev'), change: item['change_name'])
    review = { 'by' => 'jev', 'at' => now, 'mode' => verdict.mode, 'status' => verdict.status.to_s }
    review['model'] = verdict.model if verdict.model
    review['answers'] = O::Jev.summarize(verdict.answers) if verdict.answers
    review['failed'] = verdict.failed.map { |c| "#{c['condition']} (measured #{c['actual']})" } if verdict.failed&.any?
    [verdict.status == :passed && verdict.enforce?, review]
  rescue StandardError => e
    [false, { 'by' => 'jev', 'at' => now, 'status' => 'error', 'detail' => e.message[0, 300] }]
  end

  # The edits of a prompt proposal applied to its prompt, checked, and written; the
  # prompt's version before and after. Raises ApplyError and leaves the file as it was.
  def apply_prompt!(item)
    name = item['prompt'].to_s
    raise ApplyError, "prompt must be one of #{OpenSpecPrompts::PLACEHOLDERS.keys.join(', ')}" unless OpenSpecPrompts::PLACEHOLDERS.key?(name)

    rel = "#{OpenSpecPrompts::DIR}/#{name}.md"
    file = OpenSpecPrompts.path(O::ROOT, name)
    raise ApplyError, "#{rel} is missing" unless File.file?(file)

    edits = item['edits']
    unless edits.is_a?(Array) && edits.any? && edits.all? { |e| e.is_a?(Hash) && e['old'].is_a?(String) && !e['old'].empty? && e['new'].is_a?(String) }
      raise ApplyError, 'edits must be a list of {"old": <text in the prompt>, "new": <its replacement>}'
    end

    before = File.read(file, encoding: 'UTF-8')
    after = edits.each_with_index.reduce(before) do |text, (edit, i)|
      found = text.scan(edit['old']).size
      raise ApplyError, "edit #{i + 1}: its old text occurs #{found} times in #{rel}, not once (did the prompt change since?)" unless found == 1

      text.sub(edit['old']) { edit['new'] }
    end
    raise ApplyError, "the edits leave #{rel} as it is" if after == before

    from = OpenSpecPrompts.version(O::ROOT, name)
    write_text(file, after)
    errors = OpenSpecPrompts.problems(O::ROOT)[:errors].select { |e| e.start_with?("#{rel}:") }
    unless errors.empty?
      write_text(file, before)
      raise ApplyError, "the edited prompt fails its check: #{errors.join('; ')}"
    end
    { 'at' => now, 'prompt' => rel, 'from' => from, 'to' => OpenSpecPrompts.version(O::ROOT, name) }
  end

  def write_text(path, text)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.write(tmp, text)
    File.rename(tmp, path)
  end

  # A prompt proposal never reaches the backlog: approved (by prompt_approval or a
  # human), it is applied to its prompt at once.
  def review_prompt(item, counts)
    if item['status'] == 'proposed' && !item.key?('review') && prompt_approval == 'auto'
      item['status'] = 'approved'
      item['review'] = { 'by' => 'auto', 'at' => now }
    end
    case item['status']
    when 'proposed' then counts['prompt edit(s) waiting for a human'] += 1
    when 'approved'
      begin
        item['applied'] = apply_prompt!(item)
        item['status'] = 'integrated'
        item['integrated_at'] = now
        O.emit('proposal.applied', change: item['change_name'], prompt: item['applied']['prompt'],
                                   from: item['applied']['from'], to: item['applied']['to'])
        counts['prompt edit(s) applied'] += 1
      rescue ApplyError => e
        item['status'] = 'rejected'
        item['review'] = (item['review'] || {}).merge('apply_error' => e.message)
        O.emit('proposal.apply_failed', change: item['change_name'], error: e.message[0, 300])
        counts['prompt edit(s) rejected'] += 1
      end
    end
  end

  def review
    items = read(FILE)
    backlog = read(O::BACKLOG_FILE)
    history = read(O::HISTORY_FILE)
    mode = approval
    counts = Hash.new(0)
    items.each do |item|
      next unless item.is_a?(Hash) && item['change_name'].to_s.match?(O::CHANGE_NAME)
      next review_prompt(item, counts) if prompt?(item)

      if item['status'] == 'proposed' && !item.key?('review')
        case mode
        when 'auto'
          item['status'] = 'approved'
          item['review'] = { 'by' => 'auto', 'at' => now }
        when 'jev'
          approved, review = ask_jev(item, items, backlog)
          O.emit('proposal.reviewed', change: item['change_name'], status: review['status'], approved: approved)
          # An answer is kept; no answer (Jev off, unavailable or failing) is retried next cycle.
          if %w[passed failed abstained].include?(review['status'])
            item['review'] = review
            item['status'] = 'approved' if approved
          else
            counts["not reviewed (jev #{review['status']})"] += 1
          end
        end
      end
      if item['status'] == 'approved'
        unless backlog.any? { |b| b['change_name'] == item['change_name'] } ||
               history.any? { |h| h['change_name'] == item['change_name'] } ||
               archived?(item['change_name'])
          # queued_at lets the dispatcher age the item (dispatch.aging_hours of config/pipeline.yaml).
          backlog << item.reject { |k, _| OWN_FIELDS.include?(k) }.merge('queued_at' => now)
        end
        item['status'] = 'queued'
        item['queued_at'] = now
        O.emit('proposal.queued', change: item['change_name'], by: item.dig('review', 'by') || 'human')
        counts['queued'] += 1
      end
      if item['status'] == 'queued' && archived?(item['change_name'])
        item['status'] = 'integrated'
        item['integrated_at'] = now
      end
      counts["waiting for a human"] += 1 if item['status'] == 'proposed'
    end
    write(FILE, items) if File.exist?(FILE) || items.any?
    write(O::BACKLOG_FILE, backlog) if counts['queued'].positive?
    _, _, moved = O.archive_backlog!(O::ROOT, at: now)
    counts['archived'] += moved.size if moved.any?
    summary = counts.empty? ? 'nothing to review' : counts.map { |k, v| "#{v} #{k}" }.join(', ')
    puts "proposals: #{summary} (approval: #{mode}, prompt edits: #{prompt_approval})"
  end

  STATUS_RANK = { 'proposed' => 0, 'approved' => 1, 'queued' => 2, 'integrated' => 3, 'rejected' => 3 }.freeze
  # What an agent session may write (bin/lib/record.sh SCOPE), what its record
  # commits (RECORDED: the scope and the prompts), and which of them are JSON lists.
  SCOPE = %w[MEMORY.md memory config/agent_backlog.json config/agent_history.json config/agent_proposals.json].freeze
  RECORDED = [*SCOPE, 'config/prompts'].freeze
  LISTS = %w[config/agent_backlog.json config/agent_history.json config/agent_proposals.json].freeze

  # A file's text at a revision of the repository in `dir`, or nil where it has none.
  def blob(dir, rev, rel)
    res = O.git(['show', "#{rev}:#{rel}"], chdir: dir, stderr: :separate)
    res.ok? ? res.out : nil
  end

  def text_at(path) = File.file?(path) ? File.read(path, encoding: 'UTF-8') : nil

  def git_names(dir, *args)
    res = O.git(args, chdir: dir, stderr: :separate)
    raise "git #{args.first} failed in #{dir}: #{res.err}" unless res.ok?

    res.out.split("\0").reject(&:empty?)
  end

  def ancestor?(commit, of) = O.git(['merge-base', '--is-ancestor', commit, of], chdir: O::ROOT).ok?

  # Applies what `local` changed since `base` (rel => text, nil for no file) to the
  # files in O::ROOT, which hold what origin has: a three-way merge that keeps the
  # changes of both sides, JSON lists item by item and anything else line by line.
  def reconcile!(base, local)
    local.each do |rel, text|
      next if text == base[rel]

      LISTS.include?(rel) ? merge_list!(rel, base[rel], text) : merge_text!(rel, base[rel], text)
    end
    O.archive_backlog!(O::ROOT)
  end

  def merge_text!(rel, base_text, local_text)
    path = File.join(O::ROOT, rel)
    remote_text = text_at(path)
    if local_text.nil?
      FileUtils.rm_f(path) if remote_text == base_text # deleted here, unchanged there
      return
    end
    FileUtils.mkdir_p(File.dirname(path))
    return write_text(path, local_text) if remote_text.nil? || remote_text == base_text
    return if remote_text == local_text

    Dir.mktmpdir('openspec-merge-') do |dir|
      files = { 'remote' => remote_text, 'base' => base_text.to_s, 'local' => local_text }.map do |name, text|
        File.join(dir, name).tap { |f| File.write(f, text) }
      end
      # --union keeps both sides' lines where they overlap. The output is the file as
      # it is: never stripped (its last newline) nor mixed with git's stderr.
      res = O.git(['merge-file', '--union', '-p', *files], chdir: dir, stderr: :separate)
      raise "git merge-file of #{rel} failed: #{res.err}" unless res.ok?

      write_text(path, res.out)
    end
  end

  def list_of(text)
    return [] if text.nil?

    data = JSON.parse(text)
    data.is_a?(Hash) ? Array(data['changes']) : (data if data.is_a?(Array))
  rescue JSON::ParserError
    nil
  end

  # A JSON list merged by change_name: what local added, edited or removed since base
  # is applied to remote, which keeps everything else, including its own edits. Of an
  # item both sides edited, local's edit wins, or for a proposal the one further along.
  # Anything that is not a JSON list merges as text.
  def merge_list!(rel, base_text, local_text)
    path = File.join(O::ROOT, rel)
    remote_text = text_at(path)
    base, local, remote = [base_text, local_text, remote_text].map { |t| list_of(t) }
    return merge_text!(rel, base_text, local_text) if [base, local, remote].any?(&:nil?)

    key = ->(i) { i.is_a?(Hash) ? i['change_name'] : i }
    base_by = base.to_h { |i| [key[i], i] }
    local_keys = local.map { |i| key[i] }
    merged = remote.reject { |i| base_by.key?(key[i]) && !local_keys.include?(key[i]) }
    local.each do |item|
      next if base_by[key[item]] == item # unchanged here: origin's version stands

      at = merged.index { |i| key[i] == key[item] }
      if at.nil? then merged << item
      elsif merged[at] != base_by[key[item]] && rel == 'config/agent_proposals.json' then merged[at] = newer_proposal(merged[at], item)
      else merged[at] = item
      end
    end
    if rel == 'config/agent_proposals.json'
      merged.each do |item|
        next unless item.is_a?(Hash) && item['status'] == 'queued' && archived?(item['change_name'])

        item['status'] = 'integrated'
        item['integrated_at'] ||= now
      end
    end
    write(path, merged) unless merged == remote && remote_text
  end

  # Of two edits of one proposal the one further along wins (proposed, approved,
  # queued, then integrated or rejected), and a review once given is kept.
  def newer_proposal(remote, local)
    return local unless remote.is_a?(Hash) && local.is_a?(Hash)

    l = STATUS_RANK.fetch(local['status'], 0)
    r = STATUS_RANK.fetch(remote['status'], 0)
    l > r || (l == r && local.key?('review') && !remote.key?('review')) ? remote.merge(local) : local.merge(remote)
  end

  # Rebases the cycle's or visual session's record commit onto origin/<base>,
  # reconciling the memory, the backlog, the history, the proposals and any
  # prompt edits with what the merger or the other session pushed meanwhile.
  # The record is the one commit on top of what origin has; if anything fails the
  # worktree is put back on it, so a later attempt finds it as it was.
  def rebase(base)
    remote = "#{O::REMOTE}/#{base}"
    raise ArgumentError, "git fetch #{base} failed" unless O.git(['fetch', '--quiet', O::REMOTE, base], chdir: O::ROOT).ok?
    # The record had nothing left to commit, so nothing of this session's is ahead: catch up.
    return O.git!(['merge', '--ff-only', '--quiet', remote], chdir: O::ROOT) if ancestor?('HEAD', remote)
    raise ArgumentError, "HEAD is not one record commit on top of #{remote}; left as it is" unless ancestor?('HEAD~1', remote)

    head = O.git!(%w[rev-parse HEAD], chdir: O::ROOT)
    message = O.git!(%w[log -1 --format=%B HEAD], chdir: O::ROOT)
    names = git_names(O::ROOT, 'diff', '--name-only', '-z', 'HEAD~1', 'HEAD', '--', *RECORDED)
    base_texts = names.to_h { |rel| [rel, blob(O::ROOT, 'HEAD~1', rel)] }
    local_texts = names.to_h { |rel| [rel, blob(O::ROOT, 'HEAD', rel)] }
    begin
      O.git!(['reset', '--hard', '--quiet', remote], chdir: O::ROOT)
      reconcile!(base_texts, local_texts)
      stage = RECORDED.select { |f| File.exist?(File.join(O::ROOT, f)) || O.git(['ls-files', '--error-unmatch', '--', f], chdir: O::ROOT).ok? }
      O.git!(['add', '-A', '--', *stage], chdir: O::ROOT)
      O.git!(['commit', '--quiet', '-m', message], chdir: O::ROOT) unless O.git(%w[diff --cached --quiet], chdir: O::ROOT).ok?
    rescue StandardError
      O.git(['reset', '--hard', '--quiet', head], chdir: O::ROOT)
      raise
    end
  end

  # Applies the uncommitted edits of the scope in `src` (the main checkout: an
  # operator's `approve`, the visual session's findings) to this worktree, which
  # holds what origin has, with the three-way merge of `rebase`; `src` is left as
  # it is. Run from the worktree by bin/run_cycle.sh and bin/visual_qa.sh.
  def carry(src)
    src = File.expand_path(src)
    names = (git_names(src, 'diff', '--name-only', '-z', 'HEAD', '--', *SCOPE) +
             git_names(src, 'ls-files', '-z', '-o', '--exclude-standard', '--', *SCOPE)).uniq
    reconcile!(names.to_h { |rel| [rel, blob(src, 'HEAD', rel)] }, names.to_h { |rel| [rel, text_at(File.join(src, rel))] })
    puts "proposals: carried #{names.join(', ')} from #{src}" if names.any?
  end

  def decide(name, status)
    items = read(FILE)
    item = items.find { |i| i['change_name'] == name } or raise ArgumentError, "no proposal named #{name}"
    raise ArgumentError, "#{name} is #{item['status']}, not proposed" unless %w[proposed approved].include?(item['status'])

    item['status'] = status
    item['review'] = (item['review'] || {}).merge('decided_by' => 'human', 'decided_at' => now)
    write(FILE, items)
    nxt = prompt?(item) ? "the next cycle applies it to #{OpenSpecPrompts::DIR}/#{item['prompt']}.md" : 'the next cycle queues it'
    puts "proposals: #{name} #{status}#{status == 'approved' ? "; #{nxt}" : ''}"
  end

  def list
    read(FILE).each do |i|
      jev = i.dig('review', 'status') ? " jev=#{i.dig('review', 'status')}" : ''
      kind = prompt?(i) ? " prompt=#{i['prompt']}" : ''
      puts format('%-11<status>s %-40<name>s %<source>s%<kind>s%<jev>s', status: i['status'], name: i['change_name'],
                                                                           source: i['source'], kind: kind, jev: jev)
    end
  end

  # One proposal for a human to decide on; a prompt edit as a diff of its old and new text.
  def show(name)
    item = read(FILE).find { |i| i['change_name'] == name } or raise ArgumentError, "no proposal named #{name}"
    puts "#{item['change_name']} (#{item['status']}, #{prompt?(item) ? "prompt #{item['prompt']}" : 'change'}, source #{item['source'] || 'unknown'})"
    %w[description evidence].each { |k| puts "#{k}: #{item[k]}" if item[k] }
    puts "apply_error: #{item.dig('review', 'apply_error')}" if item.dig('review', 'apply_error')
    puts "applied: #{item['applied'].to_json}" if item['applied']
    Array(item['edits']).each_with_index do |edit, i|
      puts "--- edit #{i + 1} of #{OpenSpecPrompts::DIR}/#{item['prompt']}.md"
      edit['old'].to_s.each_line { |l| puts "-#{l.chomp}" }
      edit['new'].to_s.each_line { |l| puts "+#{l.chomp}" }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    case ARGV
    in ['review'] then Proposals.review
    in ['rebase', base] then Proposals.rebase(base)
    in ['carry', src] then Proposals.carry(src)
    in ['list'] then Proposals.list
    in ['show', name] then Proposals.show(name)
    in ['approve', name] then Proposals.decide(name, 'approved')
    in ['reject', name] then Proposals.decide(name, 'rejected')
    else
      warn 'Usage: ruby bin/proposals.rb review | rebase <base> | carry <checkout> | list | show <change> | ' \
           'approve <change> | reject <change>'
      exit 2
    end
  rescue ArgumentError, JSON::ParserError => e
    warn "proposals: #{e.message}"
    exit 1
  end
end
