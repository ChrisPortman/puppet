require 'puppet'
require 'puppet/parameter/boolean'

Puppet::Type.newtype(:resources) do
  @doc = "This is a metatype that can manage other resource types.  Any
    metaparams specified here will be passed on to any generated resources,
    so you can purge umanaged resources but set `noop` to true so the
    purging is only logged and does not actually happen."


  newparam(:name) do
    desc "The name of the type to be managed."

    validate do |name|
      raise ArgumentError, "Could not find resource type '#{name}'" unless Puppet::Type.type(name)
    end

    munge { |v| v.to_s }
  end

  newparam(:purge, :boolean => true, :parent => Puppet::Parameter::Boolean) do
    desc "Purge unmanaged resources.  This will delete any resource
      that is not specified in your configuration
      and is not required by any specified resources.
      Purging ssh_authorized_keys this way is deprecated; see the
      purge_ssh_keys parameter of the user type for a better alternative."

    defaultto :false

    validate do |value|
      if munge(value)
        unless @resource.resource_type.respond_to?(:instances)
          raise ArgumentError, "Purging resources of type #{@resource[:name]} is not supported, since they cannot be queried from the system"
        end
        raise ArgumentError, "Purging is only supported on types that accept 'ensure'" unless @resource.resource_type.validproperty?(:ensure)
      end
    end
  end

  newparam(:unless_system_user) do
    desc "This keeps system users from being purged.  By default, it
      does not purge users whose UIDs are less than or equal to 500, but you can specify
      a different UID as the inclusive limit."

    newvalues(:true, :false, /^\d+$/)

    munge do |value|
      case value
      when /^\d+/
        Integer(value)
      when :true, true
        500
      when :false, false
        false
      when Integer; value
      else
        raise ArgumentError, "Invalid value #{value.inspect}"
      end
    end

    defaultto {
      if @resource[:name] == "user"
        500
      else
        nil
      end
    }
  end

  newparam(:unless_system_group) do
    desc "This keeps system groups from being purged.  By default, it
      does not purge groups whose GIDs are less than or equal to 500, but you can specify
      a different GID as the inclusive limit."

    newvalues(:true, :false, /^\d+$/)

    munge do |value|
      case value
      when /^\d+/
        Integer(value)
      when :true, true
        500
      when :false, false
        false
      when Integer; value
      else
        raise ArgumentError, "Invalid value #{value.inspect}"
      end
    end

    defaultto {
      if @resource[:name] == "group"
        500
      else
        nil
      end
    }
  end

  newparam(:unless_uid) do
     desc "This keeps specific uids or ranges of uids from being purged when purge is true.
       Accepts ranges, integers and (mixed) arrays of both."

     munge do |value|
       case value
       when /^\d+/
         [Integer(value)]
       when Integer
         [value]
       when Range
         [value]
       when Array
         value
       when /^\[\d+/
         value.split(',').collect{|x| x.include?('..') ? Integer(x.split('..')[0])..Integer(x.split('..')[1]) : Integer(x) }
       else
         raise ArgumentError, "Invalid value #{value.inspect}"
       end
     end
   end

  newparam(:unless_gid) do
    desc "This keeps specific gids or ranges of gids from being purged when purge is true.
    Accepts strings (comma separated values matching /\d+/), integers and (mixed) arrays of both.
    Hint: consider the range() function from stdlib for generating large ranges of GIDs to exclude"

    munge do |value|
      case value
        #match strings:
        # 123
        # 123, 456
        when /^\d+(?:\s*,\s*\d+)*$/
          value.split(/\s*,\s*/).collect do |v|
            v.to_i
          end
        when Integer
          [value]
        when Array
          value.collect do |v|
            if v.is_a? Integer
              v
            elsif v =~ /^\d+$/
              v.to_i
            else
              raise ArgumentError, "Invalid value in array #{v.inspect}"
            end
          end
        else
          raise ArgumentError, "Invalid value #{value.inspect}"
      end
    end
  end

  newparam(:only_gid) do
    desc "Purges only groups whos GIDs are in the supplied array.
    Accepts strings (comma separated values matching /\d+/), integers and (mixed) arrays of both.
    Hint: consider the range() function from stdlib for generating large ranges of GIDs to exclude"

    munge do |value|
      case value
        #match strings:
        # 123
        # 123, 456
        when /^\d+(?:\s*,\s*\d+)*$/
          value.split(/\s*,\s*/).collect do |v|
            v.to_i
          end
        when Integer
          [value]
        when Array
          value.collect do |v|
            if v.is_a? Integer
              v
            elsif v =~ /^\d+$/
              v.to_i
            else
              raise ArgumentError, "Invalid value in array #{v.inspect}"
            end
          end
        else
          raise ArgumentError, "Invalid value #{value.inspect}"
      end
    end
  end

  def check(resource)
    @checkmethod ||= "#{self[:name]}_check"
    @hascheck ||= respond_to?(@checkmethod)
    if @hascheck
      return send(@checkmethod, resource)
    else
      return true
    end
  end

  def able_to_ensure_absent?(resource)
      resource[:ensure] = :absent
  rescue ArgumentError, Puppet::Error
      err "The 'ensure' attribute on #{self[:name]} resources does not accept 'absent' as a value"
      false
  end

  # Generate any new resources we need to manage.  This is pretty hackish
  # right now, because it only supports purging.
  def generate
    return [] unless self.purge?
    resource_type.instances.
      reject { |r| catalog.resource_refs.include? r.ref }.
      select { |r| check(r) }.
      select { |r| r.class.validproperty?(:ensure) }.
      select { |r| able_to_ensure_absent?(r) }.
      each { |resource|
        @parameters.each do |name, param|
          resource[name] = param.value if param.metaparam?
        end

        # Mark that we're purging, so transactions can handle relationships
        # correctly
        resource.purging
      }
  end

  def resource_type
    unless defined?(@resource_type)
      unless type = Puppet::Type.type(self[:name])
        raise Puppet::DevError, "Could not find resource type"
      end
      @resource_type = type
    end
    @resource_type
  end

  # Make sure we don't purge users with specific uids
  def user_check(resource)
    return true unless self[:name] == "user"
    return true unless self[:unless_system_user]
    resource[:audit] = :uid
    current_values = resource.retrieve_resource
    current_uid = current_values[resource.property(:uid)]
    unless_uids = self[:unless_uid]

    return false if system_users.include?(resource[:name])

    if unless_uids && unless_uids.length > 0
      unless_uids.each do |unless_uid|
        return false if unless_uid == current_uid
        return false if unless_uid.respond_to?('include?') && unless_uid.include?(current_uid)
      end
    end

    current_uid > self[:unless_system_user]
  end

  def group_check(resource)
    return true unless self[:name] == "group"
    return true unless self[:unless_system_group] || self[:unless_gid] || self[:only_gid]
    resource[:audit] = :gid
    current_values   = resource.retrieve_resource
    current_gid      = current_values[resource.property(:gid)]
    unless_gids      = self[:unless_gid]
    only_gids        = self[:only_gid]

    if unless_gids && unless_gids.length > 0 && only_gids && only_gids.length > 0
      #Cant use only_gid and unless_gid at the same time
      raise ArgumentError, "resources {'group':}: unless_gid and only_gid must not be used at the same time"
    end
    
    if self[:unless_system_group] && only_gids && only_gids.length > 0
      if only_gids.sort.first <= self[:unless_system_group]
        #Cant have only_gids and unless_system_group overlap
        raise ArgumentError, "resources {'group':}: unless_gid and unless_system_group must not overlap"
      end
    end

    #Do not remove real system groups regardless.
    return false if system_groups.include?(resource[:name])

    if only_gids && only_gids.length > 0
      #If only_gid is specified, make the decision purely based on only_gid, nothing else is relevant
      only_gids.respond_to?('include?') && only_gids.include?(current_gid) ? true : false
    else
      #If unless_gid is specified see if it declares the GID not to be purged
      if unless_gids && unless_gids.length > 0
        return false if unless_gids.respond_to?('include?') && unless_gids.include?(current_gid)
      end
      
      #Otherwise, if unless_system_group is specified, see if it disqualifies the GID from purging
      #If not, return true to purge the GID
      if self[:unless_system_group]
        current_gid > self[:unless_system_group]
      else
        true
      end
    end
  end

  def system_users
    %w{root nobody bin noaccess daemon sys}
  end

  def system_groups
    %w{root nobody bin noaccess daemon sys adm lp mail wheel}
  end
end
