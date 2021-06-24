Routes.included do

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

    @repo = system_fe.hit_repo(org_name, repo_name)
    pull_p = PullPresenter.new(@pull, eg_client, system_fe, @repo)
    jira_ticket = pull_p.jira_ticket_number
    if jira_ticket
      orchestrator = Orchestrator.new

      orchestrator.transition_issue_to_in_progress(pull_p.jira_issue_key!)
      orchestrator.link_issue_and_pr(pull: @pull, pr_title: subject,
        org_name: org_name, repo_name: repo_name,
        jira_issue_key: pull_p.jira_issue_key!)
    end

    redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
  end

  get '/repos/:org/:repo/pulls/:id/edit-msg' do |org_name, repo_name, pull_id|
    @pull = gh_repo(org_name, repo_name).pull(pull_id)
    rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
    rc.update_cache
    subject, message = rc.commitish_message(@pull.head_sha)
    @message = "#{subject}\n\n#{message}"

    @branch_name = @pull.head_branch_name
    slim :edit_msg
  end

  post '/repos/:org/:repo/pulls/:id/edit-msg' do |org_name, repo_name, pull_id|
    @pull = gh_repo(org_name, repo_name).pull(pull_id)
    rc = RepoCache.new(@pull.base_owner_name, @pull.head_repo_name)
    rc.update_cache
    new_message = params[:message]
    rc.set_commit_message(@pull, new_message)

    if params[:update_pr] == '1'
      subject, message = new_message.gsub("\r\n", "\n").split("\n\n", 2)
      if subject.length > 100
        extra = subject[100...subject.length]
        subject = subject[0...100] + '...'
        message = "#{extra}\n\n#{message}"
      end
      @pull.update(title: subject, body: message)
    end

    redirect return_path || "/repos/#{@pull.repo_full_name}/pulls/#{pull_id}"
  end
end
