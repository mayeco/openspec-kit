#!/usr/bin/env ruby
# frozen_string_literal: true

# ==============================================================================
# bin/portal.rb
#
# The kit's local web portal, built with Sinatra (https://github.com/sinatra/sinatra).
# Gives an operator a browser view and every action of the kit in one place:
#
#   ruby bin/portal.rb [--port 4567] [--bind 127.0.0.1]
#
# Implementation is split into:
#   - bin/lib/portal_state.rb:   read-only inspection of locks, processes,
#                                active worktrees (.worktrees/worker-*), agents,
#                                per-change PLAN and BUILD prompts, and the
#                                Agentic Observatory view of log/.
#   - bin/lib/portal_actions.rb: pause/resume, agent pings and prompt runs (on
#                                the root or inside a change's worktree), health
#                                checks, background jobs, backlog/quarantine and
#                                worker worktree operations.
#   - bin/lib/portal_ui.rb:      the single-page operator interface.
#
# Listens on 127.0.0.1 by default so only the operator's machine reaches it.
# Runtime state written by the portal lives under log/portal/ (git-ignored).
# ==============================================================================

require 'erb'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'securerandom'
require 'sinatra/base'
require 'time'
require 'yaml'
require_relative 'lib/openspec_orchestrator'
require_relative 'lib/agents'
require_relative 'lib/settings'
require_relative 'cycle_progress'
require_relative 'kit_config'
require_relative 'app_setup'
require_relative 'proposals'
require_relative 'visual_qa'
require_relative 'jev_report'
require_relative 'prompt_report'
require_relative 'lib/portal_state'
require_relative 'lib/portal_actions'
require_relative 'lib/portal_ui'

Encoding.default_external = Encoding::UTF_8

module OpenSpecPortal
  # Sinatra application serving both JSON endpoints and the single-page operator portal.
  class App < Sinatra::Base
    set :host_authorization, { permitted_hosts: [] } if respond_to?(:host_authorization)
    set :protection, false

    before do
      Encoding.default_external = Encoding::UTF_8
    end

    helpers do
      def json_response(data, code = 200)
        status code
        content_type :json
        JSON.pretty_generate(data)
      end

      def body_params
        return {} unless request.content_type.to_s.include?('json')

        raw = request.body.read
        request.body.rewind
        raw.empty? ? {} : JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def param(key)
        return params[key.to_s] if params.key?(key.to_s)
        return params[key.to_sym] if params.key?(key.to_sym)

        body_params[key.to_s]
      end
    end

    get '/' do
      content_type :html
      PORTAL_HTML
    end

    get '/api/status' do
      since = CycleProgress.parse_since(param(:since) || '24h')
      snap = OpenSpecPortal.sh('bash', File.join(ROOT, 'bin', 'cycle_status.sh'), timeout: 30)
      json_response(
        'root' => ROOT,
        'app_name' => File.basename(ROOT),
        'processes' => OpenSpecPortal.processes_and_locks,
        'worktrees' => OpenSpecPortal.worktrees_status,
        'progress' => CycleProgress.report(since),
        'snapshot' => snap.out,
        'last_health' => OpenSpecPortal.read_json(File.join(PORTAL_DIR, 'last_health.json'))
      )
    end

    get '/api/processes' do
      json_response(OpenSpecPortal.processes_and_locks)
    end

    get '/api/worktrees' do
      json_response('worktrees' => OpenSpecPortal.worktrees_status)
    end

    post '/api/worktrees/:change_name/reclaim_lease' do
      OpenSpecPortal.reclaim_lease!(params[:change_name])
      json_response('ok' => true, 'worktrees' => OpenSpecPortal.worktrees_status)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/agents' do
      json_response(
        'catalog' => OpenSpecPortal.agents_catalog,
        'runs' => OpenSpecPortal.list_runs
      )
    end

    post '/api/agents/ping' do
      agent = param(:agent).to_s.strip
      return json_response({ 'error' => 'agent is required' }, 400) if agent.empty?

      json_response(OpenSpecPortal.ping_agent(agent))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/agents/message' do
      agent = param(:agent).to_s.strip
      prompt = param(:prompt).to_s
      async = %w[1 true yes].include?(param(:async).to_s.downcase)
      json_response(OpenSpecPortal.run_agent_prompt(agent: agent, prompt: prompt, async: async))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/agents/runs/:id' do
      run = OpenSpecPortal.get_run(params[:id])
      run ? json_response(run) : json_response({ 'error' => 'run not found' }, 404)
    end

    post '/api/health' do
      services_only = %w[1 true yes services].include?(param(:mode).to_s.downcase) ||
                      %w[1 true yes].include?(param(:services).to_s.downcase)
      json_response(OpenSpecPortal.run_health_check(services_only: services_only))
    end

    post '/api/actions/pause' do
      reason = OpenSpecPortal.pause!(param(:reason))
      json_response('paused' => true, 'reason' => reason)
    end

    post '/api/actions/resume' do
      OpenSpecPortal.resume!
      if %w[1 true yes].include?(param(:drain_merge).to_s.downcase)
        job = OpenSpecPortal.start_job('merge-and-sync', 'bash', '-c', 'ruby bin/openspec_merger.rb && bash bin/sync_repos.sh')
        json_response('paused' => false, 'drained' => true, 'job' => job)
      else
        json_response('paused' => false)
      end
    end

    post '/api/actions/resume_and_merge' do
      OpenSpecPortal.resume!
      job = OpenSpecPortal.start_job('merge-and-sync', 'bash', '-c', 'ruby bin/openspec_merger.rb && bash bin/sync_repos.sh')
      json_response('ok' => true, 'paused' => false, 'job' => job)
    end

    post '/api/actions/cycle' do
      res = OpenSpecPortal.sh('bash', File.join(ROOT, 'bin', 'run_cycle.sh'), '--detach', timeout: 30)
      json_response('ok' => res.ok?, 'output' => res.out.strip)
    end

    post '/api/actions/dispatch' do
      if %w[1 true yes].include?(param(:dry_run).to_s.downcase)
        json_response(OpenSpecPortal.dry_run_queue)
      else
        job = OpenSpecPortal.start_job('dispatch', 'ruby', File.join(ROOT, 'bin', 'openspec_dispatcher.rb'))
        json_response('ok' => true, 'job' => job)
      end
    end

    post '/api/actions/merge' do
      job = OpenSpecPortal.start_job('merge', 'ruby', File.join(ROOT, 'bin', 'openspec_merger.rb'))
      json_response('ok' => true, 'job' => job)
    end

    post '/api/actions/sync' do
      args = ['bash', File.join(ROOT, 'bin', 'sync_repos.sh')]
      args << '--publish' if %w[1 true yes].include?(param(:publish).to_s.downcase)
      res = OpenSpecPortal.sh(*args, timeout: 120)
      json_response('ok' => res.ok?, 'output' => res.out)
    end

    post '/api/actions/gates' do
      args = ['bash', File.join(ROOT, 'bin', 'run_gates.sh')]
      repo = param(:repo).to_s.strip
      if !repo.empty? && repo.match?(/\A[A-Za-z0-9._-]+\z/)
        args.push('--repo', repo)
      else
        args << '--all'
      end
      args << '--regression' if %w[1 true yes].include?(param(:regression).to_s.downcase)
      job = OpenSpecPortal.start_job('gates', *args)
      json_response('ok' => true, 'job' => job)
    end

    post '/api/actions/visual_qa' do
      op = param(:op).to_s.strip
      case op
      when 'begin', 'end'
        res = OpenSpecPortal.sh('bash', File.join(ROOT, 'bin', 'visual_qa.sh'), op, timeout: 120)
        json_response('ok' => res.ok?, 'output' => res.out.strip)
      when 'request'
        what = param(:what).to_s.strip
        return json_response({ 'error' => 'what is required' }, 400) if what.empty?

        change = param(:change).to_s.strip
        VisualQA.with_lock { VisualQA.request(what, change.empty? ? nil : change) }
        json_response('ok' => true, 'queue' => VisualQA.load)
      when 'done'
        VisualQA.with_lock { VisualQA.done(param(:id), param(:verdict).to_s.strip, param(:note).to_s) }
        json_response('ok' => true, 'queue' => VisualQA.load)
      else
        json_response({ 'error' => 'op must be begin, end, request or done' }, 400)
      end
    rescue StandardError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/backlog' do
      json_response(
        'backlog' => OpenSpecPortal.backlog_items,
        'history' => OpenSpecPortal.history_items.last(30).reverse,
        'dry_run' => OpenSpecPortal.dry_run_queue
      )
    end

    post '/api/backlog' do
      item = OpenSpecPortal.add_backlog_item!(
        change_name: param(:change_name), priority: param(:priority),
        description: param(:description), depends_on: param(:depends_on)
      )
      json_response('ok' => true, 'item' => item, 'backlog' => OpenSpecPortal.backlog_items)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    delete '/api/backlog/:change_name' do
      OpenSpecPortal.delete_backlog_item!(params[:change_name])
      json_response('ok' => true, 'backlog' => OpenSpecPortal.backlog_items)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/proposals' do
      json_response('proposals' => Proposals.read(Proposals::FILE))
    end

    post '/api/proposals/:change_name/:decision' do
      decision = params[:decision]
      return json_response({ 'error' => 'decision must be approve or reject' }, 400) unless %w[approve reject].include?(decision)

      Proposals.decide(params[:change_name], decision == 'approve' ? 'approved' : 'rejected')
      json_response('ok' => true, 'proposals' => Proposals.read(Proposals::FILE))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/proposals/review' do
      Proposals.review
      json_response('ok' => true, 'proposals' => Proposals.read(Proposals::FILE))
    rescue StandardError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/blocked' do
      json_response('blocked' => OpenSpecPortal.blocked_items)
    end

    post '/api/blocked/:change_name/unblock' do
      approve = %w[1 true yes].include?(param(:approve_risk).to_s.downcase)
      reset = %w[1 true yes].include?(param(:reset_retries).to_s.downcase)
      OpenSpecPortal.unblock!(params[:change_name], approve_risk: approve, reset_retries: reset)
      json_response('ok' => true, 'blocked' => OpenSpecPortal.blocked_items)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/config' do
      topic = param(:topic)
      json_response('show' => KitConfig.show(topic), 'check' => KitConfig.check)
    end

    post '/api/config/set' do
      key = param(:key).to_s.strip
      value = param(:value).to_s
      dry_run = %w[1 true yes].include?(param(:dry_run).to_s.downcase)
      KitConfig.set(key, value, dry_run: dry_run)
      json_response('ok' => true, 'show' => KitConfig.show(nil), 'check' => KitConfig.check)
    rescue KitConfig::Error, Psych::Exception => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/setup' do
      json_response(AppSetup.status)
    end

    post '/api/setup/repo' do
      url = param(:url).to_s.strip
      name = param(:name).to_s.strip
      branch = param(:branch).to_s.strip
      force = %w[1 true yes].include?(param(:force).to_s.downcase)
      if !url.empty?
        AppSetup.add_repo(url, name: (name.empty? ? nil : name), branch: (branch.empty? ? nil : branch))
      elsif !name.empty?
        AppSetup.repo(name, force: force)
      else
        return json_response({ 'error' => 'name or url is required' }, 400)
      end
      json_response('ok' => true, 'setup' => AppSetup.status)
    rescue AppSetup::Error, KitConfig::Error, Psych::Exception => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/reports' do
      since = CycleProgress.parse_since(param(:since) || '30d')
      json_response(
        'jev' => JevReport.report(since, param(:gate)),
        'prompt' => PromptReport.report(since, 'prompt'),
        'memory' => PromptReport.report(since, 'memory')
      )
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/logs' do
      kind = param(:kind)
      name = param(:name)
      if kind
        content = OpenSpecPortal.read_log_file(kind, name || 'events.jsonl')
        return json_response({ 'error' => 'log not found' }, 404) unless content

        json_response('kind' => kind, 'name' => name, 'content' => content)
      else
        json_response(OpenSpecPortal.logs_catalog.merge('jobs' => OpenSpecPortal.list_jobs))
      end
    end

    get '/api/changes' do
      json_response('changes' => OpenSpecPortal.changes_catalog, 'templates' => OpenSpecPortal.prompt_templates_detail)
    end

    get '/api/changes/:change_name' do
      detail = OpenSpecPortal.change_detail(params[:change_name])
      detail ? json_response(detail) : json_response({ 'error' => 'change not found' }, 404)
    end

    post '/api/changes/:change_name/agent' do
      name = params[:change_name].to_s.strip
      wt = File.join(O::WORKTREE_BASE, "worker-#{name}")
      return json_response({ 'error' => "worktree #{wt} does not exist" }, 404) unless File.directory?(wt)

      agent = param(:agent).to_s.strip
      prompt = param(:prompt).to_s
      async = %w[1 true yes].include?(param(:async).to_s.downcase)
      json_response(OpenSpecPortal.run_agent_prompt(agent: agent, prompt: prompt, async: async, workdir: wt))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/changes/:change_name/validate' do
      json_response(OpenSpecPortal.validate_worker!(params[:change_name]))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/changes/:change_name/gates' do
      job = OpenSpecPortal.run_worker_gates!(params[:change_name])
      json_response('ok' => true, 'job' => job)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/changes/:change_name/reset' do
      json_response(OpenSpecPortal.reset_worker!(params[:change_name]))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  options = { port: ENV.fetch('PORT', OpenSpecPortal::DEFAULT_PORT).to_i,
              bind: ENV.fetch('BIND', OpenSpecPortal::DEFAULT_BIND) }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby bin/portal.rb [--port 4567] [--bind 127.0.0.1]'
    opts.on('-p', '--port PORT', Integer, "Port to listen on (default #{OpenSpecPortal::DEFAULT_PORT})") { |v| options[:port] = v }
    opts.on('-o', '--bind HOST', "Address to bind (default #{OpenSpecPortal::DEFAULT_BIND})") { |v| options[:bind] = v }
  end.parse!
  OpenSpecPortal.ensure_dirs!
  OpenSpecPortal::App.run!(port: options[:port], bind: options[:bind])
end

