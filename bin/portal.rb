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
#   - bin/lib/portal_index.rb:   paginated, filterable views: changes, executions,
#                                cycles, events, runs, history and the dashboard.
#   - bin/lib/portal_actions.rb: pause/resume, agent pings, prompt runs (on the root
#                                or inside a change's worktree) that can be continued,
#                                re-run or stopped, health checks, background jobs,
#                                backlog/quarantine and worker worktree operations.
#   - bin/lib/portal_ui.rb:      the single-page operator interface, one URL per view
#                                (its pages are in bin/lib/portal_ui/).
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
require_relative 'lib/portal_index'
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

      def int(key, default)
        Integer(param(key).to_s, 10)
      rescue ArgumentError
        default
      end

      def paging = { page: int(:page, 1), per: int(:per, OpenSpecPortal::PER_PAGE) }

      def flag(key) = %w[1 true yes].include?(param(key).to_s.downcase)
    end

    get '/assets/portal.css' do
      content_type 'text/css'
      cache_control :no_store
      OpenSpecPortal.ui_css
    end

    get '/assets/portal.js' do
      content_type 'application/javascript'
      cache_control :no_store
      OpenSpecPortal.ui_js
    end

    get '/api/summary' do
      json_response(OpenSpecPortal.summary)
    end

    get '/api/dashboard' do
      json_response(OpenSpecPortal.dashboard)
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
        'runs' => OpenSpecPortal.list_runs(10, output: false)
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

    get '/api/runs' do
      json_response(OpenSpecPortal.runs_index(status: param(:status), agent: param(:agent), change: param(:change),
                                              q: param(:q), **paging))
    end

    get '/api/runs/:id' do
      run = OpenSpecPortal.get_run(params[:id])
      run ? json_response(run) : json_response({ 'error' => 'run not found' }, 404)
    end

    post '/api/runs/:id/continue' do
      json_response(OpenSpecPortal.continue_run!(params[:id], prompt: param(:prompt), agent: param(:agent),
                                                              context: !%w[0 false no].include?(param(:context).to_s.downcase),
                                                              async: !%w[0 false no].include?(param(:async).to_s.downcase)))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/runs/:id/rerun' do
      json_response(OpenSpecPortal.rerun_run!(params[:id], agent: param(:agent), async: true))
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    post '/api/runs/:id/stop' do
      OpenSpecPortal.stop_run!(params[:id])
      json_response('ok' => true)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/jobs' do
      json_response(OpenSpecPortal.jobs_index(status: param(:status), **paging))
    end

    get '/api/jobs/:id' do
      job = OpenSpecPortal.get_job(params[:id])
      job ? json_response(job) : json_response({ 'error' => 'job not found' }, 404)
    end

    post '/api/jobs/:id/stop' do
      OpenSpecPortal.stop_job!(params[:id])
      json_response('ok' => true)
    rescue ArgumentError => e
      json_response({ 'error' => e.message }, 400)
    end

    get '/api/executions' do
      json_response(OpenSpecPortal.executions_index(kind: param(:kind), q: param(:q), change: param(:change),
                                                    page: int(:page, 1), per: int(:per, 50)))
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
      json_response('backlog' => OpenSpecPortal.backlog_items)
    end

    # What the dispatcher would start next and why each pending item waits (a subprocess: a few seconds).
    get '/api/plan' do
      json_response(OpenSpecPortal.dry_run_queue)
    end

    get '/api/history' do
      json_response(OpenSpecPortal.history_index(q: param(:q), **paging))
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
      kind = param(:kind).to_s
      return json_response({ 'error' => 'kind is required (cycle, report, worker, events, run, job)' }, 400) if kind.empty?

      tail = int(:tail, 300_000)
      file = OpenSpecPortal.log_file(kind, param(:name) || 'events.jsonl', tail: tail)
      return json_response({ 'error' => 'log not found' }, 404) unless file

      json_response(file.merge('kind' => kind, 'name' => param(:name)))
    end

    get '/api/logs/raw' do
      file = OpenSpecPortal.log_file(param(:kind).to_s, param(:name) || 'events.jsonl')
      halt 404, 'log not found' unless file

      content_type 'text/plain; charset=utf-8'
      attachment File.basename(param(:name).to_s) if flag(:download)
      file['content']
    end

    get '/api/events' do
      json_response(OpenSpecPortal.events_index(event: param(:event), change: param(:change), q: param(:q), **paging))
    end

    get '/api/cycles' do
      json_response(OpenSpecPortal.cycles_index(q: param(:q), **paging))
    end

    get '/api/cycles/:stamp' do
      detail = OpenSpecPortal.cycle_detail(params[:stamp])
      detail ? json_response(detail) : json_response({ 'error' => 'cycle not found' }, 404)
    end

    get '/api/visual' do
      json_response(OpenSpecPortal.visual_overview(**paging))
    end

    get '/api/recovery' do
      json_response(OpenSpecPortal.recovery_state)
    end

    get '/api/prompts' do
      json_response('templates' => OpenSpecPortal.prompt_templates_detail)
    end

    get '/api/changes' do
      json_response(OpenSpecPortal.changes_index(q: param(:q), state: param(:state), sort: param(:sort), **paging))
    end

    get '/api/changes/:change_name' do
      detail = OpenSpecPortal.change_detail(params[:change_name])
      detail ? json_response(detail) : json_response({ 'error' => 'change not found' }, 404)
    end

    get '/api/changes/:change_name/file' do
      file = OpenSpecPortal.change_file(params[:change_name], param(:kind).to_s, param(:name).to_s, tail: int(:tail, 300_000))
      return json_response(file) if file && !file.key?('error')

      json_response({ 'error' => file ? file['error'] : 'file not found' }, 404)
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

    # Every other path gets the shell, last so that no route above is shadowed: the browser picks the page from the URL.
    get '/*' do
      pass if request.path_info.start_with?('/api/', '/assets/')

      content_type :html
      cache_control :no_store
      OpenSpecPortal.ui_shell
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

