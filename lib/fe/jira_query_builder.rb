class JiraQueryBuilder
  PROJECT_ALIASES = {
    'lmc' => 'libmongocrypt',
  }.freeze

  TYPES = %w(
    epic bug
  ).freeze

  PROJECTS = %w(
    ruby mongoid server help docs docsp dop drivers spec website evg init pm
    node godriver prodtriage mms build
  ).freeze

  COMPONENTS = {
    'ruby' => %w(bson kerberos),
  }.freeze

  def initialize(query)
    @smart_query = query
  end

  attr_reader :smart_query

  def expanded_query
    query = []
    parts = smart_query.strip.split(/\s+/)
    project = nil
    tail = nil
    until parts.empty?
      part = parts.shift
      dpart = part.downcase
      if dpart == 'and'
        query << parts.join(' ')
        parts = []
      elsif dpart == 'order'
        tail = dpart + ' ' + parts.join(' ')
        parts = []
      elsif dpart == 'rme'
        query << 'reporter = currentUser()'
      elsif dpart == 'ame'
        query << 'assignee = currentUser()'
      elsif dpart == 'doc'
        query << 'project in (docs,docsp,dop)'
      elsif dpart == 'rm'
        query << 'project in (ruby,mongoid)'
      elsif PROJECT_ALIASES.key?(dpart)
        project = PROJECT_ALIASES[dpart]
        query << "project in (#{project})"
      elsif PROJECTS.include?(dpart)
        query << "project in (#{part})"
        project = dpart
      elsif %w(open).include?(dpart)
        query << "resolution in (unresolved)"
      elsif project && COMPONENTS[project]&.include?(dpart)
        query << "component in (#{part})"
      elsif TYPES.include?(dpart)
        query << "type in (#{part})"
      elsif dpart == 'imp'
        query << "type in (improvement, \"new feature\")"
      elsif parts.length > 0 &&
        (bits = [dpart, parts.first.downcase]) == %w(spec compliance)
      then
        parts.shift
        component = bits.join(' ')
        query << "component in ('#{component}')"
      else
        text = ([part] + parts).join(' ')
        query << %Q,(summary ~ "#{text}" or description ~ "#{text}"),
        parts = []
      end
    end
    query = query.join(' and ')
    if tail
      query += ' ' + tail
    end
    query
  end
end
