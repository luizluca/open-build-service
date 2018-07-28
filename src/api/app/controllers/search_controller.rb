class SearchController < ApplicationController
  require_dependency 'xpath_engine'

  def project
    search(:project, true)
  end

  def project_id
    search(:project, false)
  end

  def package
    search(:package, true)
  end

  def package_id
    search(:package, false)
  end

  def repository_id
    search(:repository, false)
  end

  def issue
    search(:issue, true)
  end

  def person
    search(:person, true)
  end

  def bs_request
    search(:request, true)
  end

  def bs_request_id
    search(:request, false)
  end

  def channel
    search(:channel, true)
  end

  def channel_binary
    search(:channel_binary, true)
  end

  def channel_binary_id
    search(:channel_binary, false)
  end

  def released_binary
    search(:released_binary, true)
  end

  def released_binary_id
    search(:released_binary, false)
  end

  def attribute
    unless params[:namespace] && params[:name]
      render_error status: 400, message: 'need namespace and name parameter'
      return
    end
    find_attribute(params[:namespace], params[:name])
  end

  def missing_owner
    params[:limit] ||= '0' # unlimited by default

    @owners = OwnerMissingSearch.new(params).find.map(&:to_hash)
  end

  def owner_group_or_user
    if params[:user].present?
      obj = User.find_by_login!(params[:user])
    elsif params[:group].present?
      obj = Group.find_by_title!(params[:group])
    else
      return
    end
    OwnerSearch.new(params).for(obj)
  end

  def owner_package_or_project
    return if params[:project].blank?
    if params[:package].present?
      obj = Package.get_by_project_and_name(params[:project], params[:package])
    else
      obj = Project.get_by_name(params[:project])
    end
    OwnerOfContainerSearch.new(params).for(obj)
  end

  def owner
    Backend::Test.start if Rails.env.test?

    if params[:binary].present?
      owners = OwnerAssigneeSearch.new(params).for(params[:binary])
    else
      owners = owner_group_or_user
    end
    owners ||= owner_package_or_project

    if owners.nil?
      render_error status: 400, errorcode: 'no_binary',
                    message: "The search needs at least a 'binary' or 'user' parameter"
      return
    end

    @owners = owners.map(&:to_hash)
  end

  def predicate_from_match_parameter(p)
    pred = case p
           when /^\(\[(.*)\]\)$/
             Regexp.last_match(1)
           when /^\[(.*)\]$/
             Regexp.last_match(1)
           else
             p
    end
    pred = '*' if pred.blank?
    pred
  end

  def filter_items(items)
    begin
      @offset = Integer(params[:offset])
    rescue
      @offset = 0
    end
    begin
      @limit = Integer(params[:limit])
    rescue
      @limit = items.size
    end
    nitems = []
    items.each do |item|
      if @offset > 0
        @offset -= 1
      else
        nitems << item
        if @limit
          @limit -= 1
          break if @limit.zero?
        end
      end
    end
    nitems
  end

  # unfortunately read_multi hangs with just too many items
  # so maximize the keys to query
  def read_multi_workaround(keys)
    ret = {}
    until keys.empty?
      slice = keys.slice!(0, 300)
      ret.merge!(Rails.cache.read_multi(*slice))
    end
    ret
  end

  def filter_items_from_cache(items, xml, key_template)
    # ignore everything that is already in the memcache
    id2cache_key = {}
    items.each { |i| id2cache_key[i] = key_template % i }
    cached = read_multi_workaround(id2cache_key.values)
    search_items = []
    items.each do |i|
      key = id2cache_key[i]
      if cached.key? key
        xml[i] = cached[key]
      else
        search_items << i
      end
    end
    search_items
  end

  def search(what, render_all)
    if render_all && params[:match].blank?
      render_error status: 400, errorcode: 'empty_match',
                   message: 'No predicate found in match argument'
      return
    end

    predicate = predicate_from_match_parameter(params[:match])

    logger.debug "searching in #{what}s, predicate: '#{predicate}'"

    xe = XpathEngine.new

    items = xe.find("/#{what}[#{predicate}]")

    matches = items.size

    if params[:offset] || params[:limit]
      # Add some pagination. Limiting the ids we have
      items = filter_items(items)
    end

    includes = nil
    opts = {}

    output = "<collection matches=\"#{matches}\">\n"

    xml = {} # filled by filter
    if render_all
      key_template = "xml_#{what}_%d"
    else
      key_template = "xml_id_#{what}_%d"
    end
    search_items = filter_items_from_cache(items, xml, key_template)

    case what
    when :package
      relation = Package.where(id: search_items)
      includes = [:project]
    when :project
      relation = Project.where(id: search_items)
      if render_all
        includes = [:repositories]
      else
        includes = []
        relation = relation.select('projects.id,projects.name')
      end
    when :repository
      relation = Repository.where(id: search_items)
      includes = [:project]
    when :request
      relation = BsRequest.where(id: search_items)
      includes = [:bs_request_actions, :reviews]
      opts[:withhistory] = 1 if params[:withhistory]
      opts[:withfullhistory] = 1 if params[:withfullhistory]
    when :person
      relation = User.where(id: search_items)
      includes = []
    when :channel
      relation = ChannelBinary.where(id: search_items)
      includes = []
    when :channel_binary
      relation = ChannelBinary.where(id: search_items)
      includes = []
    when :released_binary
      relation = BinaryRelease.where(id: search_items)
      includes = []
    when :issue
      relation = Issue.where(id: search_items)
      includes = [:issue_tracker]
    else
      logger.fatal "strange model: #{what}"
    end
    relation = relation.includes(includes).references(includes)

    # TODO: support sort_by and order parameters?

    unless items.empty?
      relation.each do |item|
        next if xml[item.id]
        xml[item.id] = render_all ? item.to_axml(opts) : item.to_axml_id
        xml[item.id].gsub!(/(..*)/, '  \\1') # indent it by two spaces, if line is not empty
      end
    end

    items.each do |i|
      output << xml[i]
    end

    output << '</collection>'
    render xml: output
  end

  # specification of this function:
  # supported paramters:
  # namespace: attribute namespace (required string)
  # name: attribute name  (required string)
  # project: limit search to project name (optional string)
  # package: limit search to package name (optional string)
  # ignorevalues: do not output attribute values (optional boolean)
  # withproject: output project defaults if no value set for package (optional boolean)
  #              such values also map against value paramter if given
  # value: limit search to attributes with value (optional string)
  # value_substr: limit search to attributes that match value substring (optional string)
  #
  # output: XML <attribute namespace name><project name>values? packages?</project></attribute>
  #         with packages = <package name>values?</package>
  #          and values   = <values>value+</values>
  #          and value    = <value>CDATA</value>
  def find_attribute(namespace, name)
    attrib = AttribType.find_by_namespace_and_name!(namespace, name)

    # gather the relation for attributes depending on project/package combination
    if params[:package] && params[:project]
      attribs = Package.get_by_project_and_name(params[:project], params[:package]).attribs
    elsif params[:package]
      attribs = attrib.attribs.where(package_id: Package.where(name: params[:package]))
    elsif params[:project]
      attribs = attrib.attribs.where(package_id: Project.get_by_name(params[:project]).packages)
    else
      attribs = attrib.attribs
    end

    # get the values associated with the attributes and store them
    attribs = attribs.pluck(:id, :package_id)
    values = AttribValue.where('attrib_id IN (?)', attribs.collect { |a| a[0] })
    attrib_values = {}
    values.each do |v|
      attrib_values[v.attrib_id] ||= []
      attrib_values[v.attrib_id] << v
    end
    # retrieve the package name and project for the attributes
    packages = Package.where('packages.id IN (?)', attribs.collect { |a| a[1] }).pluck(:id, :name, :project_id)
    pack2attrib = {}
    attribs.each do |attrib_id, pkg|
      pack2attrib[pkg] = attrib_id
    end
    packages.sort! { |x, y| x[0] <=> y[0] }
    projects = Project.where(id: packages.collect { |p| p[2] }).distinct.pluck(:id, :name)
    builder = Builder::XmlMarkup.new(indent: 2)
    xml = builder.attribute(namespace: namespace, name: name) do
      projects.each do |prj_id, prj_name|
        builder.project(name: prj_name) do
          packages.each do |pkg_id, pkg_name, pkg_prj|
            next if pkg_prj != prj_id
            builder.package(name: pkg_name) do
              values = attrib_values[pack2attrib[pkg_id]]
              unless values.nil?
                builder.values do
                  values.each { |v| builder.value(v.value) }
                end
              end
            end
          end
        end
      end
    end
    render xml: xml
  end
end
