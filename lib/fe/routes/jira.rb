autoload :JiraQueryBuilder, 'fe/jira_query_builder'

Routes.included do

  get '/jira/query' do
    if params[:q] && !params[:edit]
      do_query
    else
      @query = params[:q]
      @queries = JiraQuery.recent
      slim :jira_query
    end
  end

  post '/jira/query' do
    do_query
  end

  def do_query
    smart_query = params[:q]
    query = JiraQueryBuilder.new(smart_query).expanded_query
    jq = JiraQuery.find_or_create_by(input_text: smart_query)
    jq.save!
    redirect "https://jira.mongodb.org/issues/?jql=#{CGI.escape(query)}"
  end

  get '/jira/editmeta' do
    @heading = 'Edit Meta'
    @payload = jirra_client.get_issue_editmeta('RUBY-1690')
    slim :editmeta
  end

  get '/jira/transitions' do
    @heading = 'Transitions'
    @payload = jirra_client.get_issue_transitions('RUBY-1690')
    slim :editmeta
  end

  get '/jira/statuses' do
    @heading = 'Statuses'
    @payload = jirra_client.project_statuses('RUBY')
    slim :editmeta
  end

  get '/jira/:project' do |project_name|
    @project_name = project_name.upcase
    @versions = jirra_client.project_versions(@project_name)
    @unreleased_versions = @versions.select do |version|
      !version['released']
    end
    slim :jira_project
  end

  get '/jira/:project/fixed/:version' do |project_name, version|
    @project_name = project_name.upcase
    @version = version
    extra_conds = ''
    all_versions = jirra_client.project_versions(@project_name)
    unreleased_versions = all_versions.reject(&:released?)
    index = unreleased_versions.map(&:name).index(version)
    if index && index > 0
      @lower_fix_version = unreleased_versions[index-1].name
    end
    if params[:exclusive]
      exclude_versions = all_versions.select(&:released?).sort_by(&:release_date).
        reverse[0..4].map(&:name)
      # Remove version being looked at in case we look at it after it
      # has been released
      exclude_versions.delete(version)
      unless exclude_versions.empty?
        extra_conds << " and fixversion not in (#{exclude_versions.map { |v| "\"#{v}\"" }.join(',')})"
      end
      @excluded_versions = exclude_versions
    elsif params[:smart]
      parts = version.split('.')[0..1].map(&:to_i)
      if parts.last > 0
        lb_parts = [parts.first, parts.last-1]
      else
        lb_parts = [parts.first-1]
      end

      lb = Gem::Version.new(lb_parts.map(&:to_s).join('.'))
      hb = Gem::Version.new(version.split('.')[0..2].join('.'))

      exclude_versions = all_versions.select(&:released?).map do |version|
        begin
          v = version.gem_version
          if v >= lb && v < hb
            version.name
          end
        rescue ArgumentError
          nil
        end
      end.compact
      # When version is 7.1.0.rc0 it compares less than 7.1.0, thus
      # would end up in exclude_versions
      exclude_versions.delete(version)

      unless exclude_versions.empty?
        extra_conds << " and fixversion not in (#{exclude_versions.map { |v| "\"#{v}\"" }.join(',')})"
      end
      @excluded_versions = exclude_versions
    end
    res = jirra_client.jql(<<-jql, max_results: 500, fields: %w(summary description issuetype))
      project=#{@project_name}
      and fixversion=#{version}
      and (labels is empty or labels not in (no-changelog))
      #{extra_conds}
      order by type, priority desc, key
jql
    @issues = res.map do |info|
      OpenStruct.new(info)
    end
    @issues.sort_by! do |issue|
      case issue.fields['issuetype']['name']
      when 'Epic'
        1
      when 'New Feature'
        2
      when 'Improvement'
        3
      when 'Task'
        4
      when 'Bug'
        5
      else
        10
      end
    end
    slim :fixed_issues
  end

  get '/jira/:project/epics' do |project_name|
    project_name = project_name.upcase
    @issues = JIRA::Resource::Issue.jql(jira_client,
      "project=#{project_name} and type=epic order by resolution desc, updated desc",
      max_results: 50)
    slim :epics
  end

  get '/jira/:project/changelogs' do |project_name|
    @jira_project = project_name = project_name.upcase
    @versions = jirra_client.project_versions(project_name).select do |version|
      !version['released']
    end
    slim :changelogs
  end

  get '/jira/:project/:issue_key/no-changelog' do |project_name, issue_key|
    @project_name = project_name.upcase
    @issue_key = issue_key.upcase
    jirra_client.edit_issue(@issue_key, add_labels: %w(no-changelog))
    redirect return_path
  end

  get '/jira/:project/:issue_key/set-fix-version/:fix_version' do |project_name, issue_key, new_fix_version|
    @project_name = project_name.upcase
    @issue_key = issue_key.upcase
    jirra_client.edit_issue(@issue_key, set_fix_versions: [new_fix_version])
    redirect return_path
  end
end
