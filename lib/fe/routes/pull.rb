module Routes
module Pull
  extend ActiveSupport::Concern

  included do

    # pull
    get '/repos/:org/:repo/pulls/:id' do |org_name, repo_name, id|
      @repo = system.hit_repo(org_name, repo_name)
      pull = gh_repo(org_name, repo_name).pull(id)
      @pull = PullPresenter.new(pull, eg_client, system, @repo)
      @statuses = @pull.statuses
      @configs = {
        'mongodb-version' => %w(4.0 3.6 3.4 3.2 3.0 2.6 latest),
        'topology' => %w(standalone replica-set sharded-cluster),
        'auth-and-ssl' => %w(noauth-and-nossl auth-and-ssl),
      }
      @ruby_versions = %w(2.6 2.5 2.4 2.3 2.2 1.9 head jruby-9.2 jruby-9.1)
      @table_keys = %w(mongodb-version topology auth-and-ssl ruby)
      @category_values = {}
      @table = {}
      @untaken_statuses = []
      @pull.statuses.each do |status|
        if repo_name == 'mongo-ruby-driver' && status.status.context =~ %r,evergreen/,
          id = status.status.context.split('/')[1]
          label, rest = id.split('__')
          meta = {}
          rest.split('_').each do |pair|
            key, value = pair.split('~')
            case key
            when 'ruby'
              meta[key] = value.sub(/^ruby-/, '')
            else
              meta[key] = value
            end
          end
          if label =~ /enterprise-auth-tests-ubuntu/
            meta['mongodb-version'] = 'EA'
            meta['topology'] = 'ubuntu'
          elsif label =~ /enterprise-auth-tests-rhel/
            meta['mongodb-version'] = 'EA'
            meta['topology'] = 'rhel'
          else
            meta['auth-and-ssl'] ||= 'noauth-and-nossl'
          end
          @table_keys.each do |key|
            value = meta[key]
            if value.nil?
              raise "Missing #{key} in #{meta}"
            end
            @category_values[key] ||= []
            (@category_values[key] << value).uniq!
          end
          meta_for_label = meta.dup
          map = @table_keys.inject(@table) do |map, key|
            (map[meta[key]] ||= {}).tap do
              meta_for_label.delete(key)
            end
          end
          short_label = ''
          if meta_for_label.delete('as')
            short_label << 'AS'
          end
          if meta_for_label.delete('lint')
            short_label << 'L'
          end
          if meta_for_label.delete('retry-writes')
            short_label << 'RW'
          end
          if compressor = meta_for_label.delete('compressor')
            short_label << compressor[0].upcase
          end
          if meta_for_label.empty?
            if short_label.empty?
              short_label = '*'
            end
          else
            extra = meta_for_label.map { |k, v| "#{k}=#{v}" }.join(',')
            if short_label.empty?
              short_label = extra
            else
              short_label += '; ' + extra
            end
          end
          if map[short_label]
            raise "overwrite for #{short_label} #{meta.inspect}"
          end
          map[short_label] = status
        else
          @untaken_statuses << status
        end
      end
      @branch_name = @pull.head_branch_name
      if repo_name == 'mongo-ruby-driver' && @category_values
        @category_values['ruby']&.sort! do |a, b|
          if a =~ /^[0-9]/ && b =~ /^[0-9]/ || a =~ /^j/ && b =~ /^j/
            b <=> a
          else
            a <=> b
          end
        end
        @category_values['mongodb-version']&.sort! do |a, b|
          if a =~ /^[0-9]/ && b =~ /^[0-9]/
            b <=> a
          else
            a <=> b
          end
        end
        @category_values['mongodb-version']&.delete('EA')
        @category_values['mongodb-version']&.push('EA')
        if @category_values['topology']
          @category_values['topology'] = %w(standalone replica-set sharded-cluster rhel ubuntu)
        end
      end
      if @category_values.empty?
        @category_values = nil
      end
      @current_eg_project_id = @pull.evergreen_project_id
      slim :pull
    end

    # pull perf
    get '/repos/:org/:repo/pulls/:id/perf' do |org_name, repo_name, id|
      @repo = system.hit_repo(org_name, repo_name)
      pull = gh_repo(org_name, repo_name).pull(id)
      @pull = PullPresenter.new(pull, eg_client, system, @repo)
      @statuses = @pull.statuses.sort_by do |status|
        if status.build_id.nil?
          # top level build
          -1000000
        else
          -status.time_taken
        end
      end
      @branch_name = @pull.head_branch_name
      slim :pull_perf
    end

    # pr log
    get '/repos/:org/:repo/pulls/:id/evergreen-log/:build_id' do |org_name, repo_name, pull_id, build_id|
      pull = gh_repo(org_name, repo_name).pull(pull_id)
      title = "#{repo_name}/#{pull_id} by #{pull.creator_name} [#{pull.head_branch_name}]"
      do_evergreen_log(build_id, title)
    end

    get '/repos/:org/:repo/pulls/:id/restart/:build_id' do |org_name, repo_name, pull_id, build_id|
      build = Evergreen::Build.new(eg_client, build_id)
      build.restart
      redirect "/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/restart-failed' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      @statuses = @pull.statuses
      restarted = false

      @pull.travis_statuses.each do |status|
        if status.failed?
          status.restart
        end
        restarted = true
      end

      status = @pull.top_evergreen_status
      if status
        version_id = File.basename(status['target_url'])
        version = Evergreen::Version.new(eg_client, version_id)
        version.restart_failed_builds
        restarted = true
      end

      unless restarted
        return 'Could not find anything to restart'
      end

      redirect return_path || "/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/restart-all' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)

      status = @pull.top_evergreen_status
      if status
        version_id = File.basename(status['target_url'])
        version = Evergreen::Version.new(eg_client, version_id)
        version.restart_all_builds
        restarted = true
      end

      unless restarted
        return 'Could not find anything to restart'
      end

      redirect return_path || "/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/request-review' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      @statuses = @pull.request_review('saghm')

      jira_ticket = @pull.jira_ticket_number
      if jira_ticket
        pr_url = "https://github.com/#{org_name}/#{repo_name}/pull/#{pull_id}"
        # https://developer.atlassian.com/server/jira/platform/jira-rest-api-for-remote-issue-links/
        payload = {
          globalId: "#{@pull.jira_project}-#{jira_ticket}-pr-#{pull_id}",
          object: {
            url: pr_url,
            title: "Fix - PR ##{pull_id}",
            icon: {"url16x16":"https://github.com/favicon.ico"},
            status: {
              icon: {},
            },
          },
        }
        jirra_client.post_json("issue/#{@pull.jira_project.upcase}-#{jira_ticket}/remotelink", payload)

        # https://stackoverflow.com/questions/21738782/does-the-jira-rest-api-require-submitting-a-transition-id-when-transitioning-an
        # https://developer.atlassian.com/server/jira/platform/jira-rest-api-example-edit-issues-6291632/
        transitions = jirra_client.get_json("issue/#{@pull.jira_project.upcase}-#{jira_ticket}/transitions")
        transition = transitions['transitions'].detect do |tr|
          tr['name'] == 'In Code Review'
        end
        if transition
          transition_id = transition['id']

          payload = {
            fields: {
              assignee: {
                name: 'oleg.pudeyev',
              },
            },
            transition: {
              id: transition_id,
            },
          }
          jirra_client.post_json("issue/#{@pull.jira_project.upcase}-#{jira_ticket}/transitions", payload)
        end
      end

      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/rebase' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
      rc.update_cache
      rc.rebase(@pull)

      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/reword' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
      rc.update_cache
      rc.reword(@pull, jirra_client)
      subject, message = rc.commitish_message(@pull.head_branch_name)
      @pull.update(title: subject, body: message)

      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/retitle' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
      rc.update_cache
      subject, message = rc.commitish_message(@pull.head_sha)
      @pull.update(title: subject, body: message)

      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    get '/repos/:org/:repo/pulls/:id/submit-patch' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
      rc.update_cache
      rc.add_remote(@pull.head_owner_name, @pull.head_repo_name)
      diff = rc.diff_to_master(@pull.head_sha)
      repo = system.hit_repo(org_name, repo_name)
      rv = eg_client.create_patch(
        project_id: repo.evergreen_project_id,
        diff_text: diff,
        base_sha: rc.master_sha,
        description: "PR ##{pull_id}: #{@pull.title}",
        variant_ids: ['all'],
        task_ids: ['all'],
        finalize: true,
      )

      patch_id = rv['patch']['Id']

      # TODO record patch internally and link it to the PR

      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    # pull bump
    get '/repos/:org/:repo/pulls/:id/bump' do |org_name, repo_name, pull_id|
      @pull = gh_repo(org_name, repo_name).pull(pull_id)
      version = Evergreen::Version.new(eg_client, @pull.evergreen_version_id)
      do_bump(version, params[:priority].to_i)
      redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
    end

    # eg authorize pr
    get '/repos/:org/:repo/pulls/:id/authorize/:patch' do |org_name, repo_name, pull_id, patch_id|
      patch = Evergreen::Patch.new(eg_client, patch_id)
      patch.authorize!
      redirect return_path || "/repos/#{org_name}/#{repo_name}/pulls/#{pull_id}"
    end
  end
end
end