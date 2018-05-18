# Populates a dynamic drop down with the Locations from a Satellite Organization
# filtered by tags on the providers available.
#
@DEBUG = false

require 'apipie-bindings'

TAG_CATEGORY = 'location'

# Log an error and exit.
#
# @param msg Message to error with
def error(msg)
  $evm.log(:error, msg)
  $evm.root['ae_result'] = 'error'
  $evm.root['ae_reason'] = msg.to_s
  exit MIQ_STOP
end

# Gets all of the Tags in a given Tag Category
#
# @param category Tag Category to get all of the Tags for
#
# @return Hash of Tag names mapped to Tag descriptions
#
# @source https://pemcg.gitbooks.io/mastering-automation-in-cloudforms-4-2-and-manage/content/using_tags_from_automate/chapter.html#_getting_the_list_of_tags_in_a_category
def get_category_tags(category)
  classification = $evm.vmdb(:classification).find_by_name(category)
  tags = {}
  $evm.vmdb(:classification).where(:parent_id => classification.id).each do |tag|
    tags[tag.name] = tag.description
  end
  
  return tags
end


# Create a Tag in a given Category if it does not already exist
#
# @param category Tag Category to create the Tag in
# @param tag      Tag to create in the given Tag Category
#
# @source https://pemcg.gitbooks.io/mastering-automation-in-cloudforms-4-2-and-manage/content/using_tags_from_automate/chapter.html
def create_tag(category, tag)
  create_tag_category(category)
  tag_name = to_tag_name(tag)
  unless $evm.execute('tag_exists?', category, tag_name)
    $evm.execute('tag_create',
                 category,
                 :name => tag_name,
                 :description => tag)
  end
end

# Create a Tag  Category if it does not already exist
#
# @param category     Tag Category to create
# @param description  Tag Category description.
#                     Optional
#                     Defaults to the `category`
# @param single_value True if a resource can only have one tag from this category,
#                     False if a resource can have multiple tags from this category.
#                     Optional.
#                     Defaults to `false`
#
# @source https://pemcg.gitbooks.io/mastering-automation-in-cloudforms-4-2-and-manage/content/using_tags_from_automate/chapter.html
def create_tag_category(category, description = nil, single_value = false)
  category_name = to_tag_name(category)
  unless $evm.execute('category_exists?', category_name)
    $evm.execute('category_create',
                 :name => category_name,
                 :single_value => single_value,
                 :perf_by_tag => false,
                 :description => description || category)
  end
end

# Takes a string and makes it a valid tag name
#
# @param str String to turn into a valid Tag name
#
# @return Given string transformed into a valid Tag name
def to_tag_name(str)
  return str.downcase.gsub(/[^a-z0-9_]+/,'_')
end

# Gets an ApiPie binding to the Satellite API.
#
# @return ApipieBindings to the Satellite API
SATELLITE_CONFIG_URI = 'Integration/Satellite/Configuration/default'
def get_satellite_api()
  satellite_config = $evm.instantiate(SATELLITE_CONFIG_URI)
  error("Satellite Configuration not found") if satellite_config.nil?
  
  satellite_server   = satellite_config['satellite_server']
  satellite_username = satellite_config['satellite_username']
  satellite_password = satellite_config.decrypt('satellite_password')
  
  $evm.log(:info, "satellite_server   = #{satellite_server}") if @DEBUG
  $evm.log(:info, "satellite_username = #{satellite_username}") if @DEBUG
  
  error("Satellite Server configuration not found")   if satellite_server.nil?
  error("Satellite User configuration not found")     if satellite_username.nil?
  error("Satellite Password configuration not found") if satellite_password.nil?
  
  satellite_api = ApipieBindings::API.new({:uri => satellite_server, :username => satellite_username, :password => satellite_password, :api_version => 2})
  $evm.log(:info, "satellite_api = #{satellite_api}") if @DEBUG
  return satellite_api
end

# @param visible_and_required Boolean true if the dialog element is visible and required, false if hidden
# @param values               Hash    Values for the dialog element
# @param default_value        String  
def return_dialog_element(visible_and_required, values, default_value = nil)
  # create dialog element
  dialog_field = $evm.object
  dialog_field['data_type']     = "String"
  dialog_field['visible']       = visible_and_required
  dialog_field['required']      = visible_and_required
  dialog_field['values']        = values
  dialog_field['default_value'] = default_value
  dialog_field['required']      = true
  $evm.log(:info, "dialog_field['values'] => #{dialog_field['values']}") if @DEBUG
  
  exit MIQ_OK
end

begin
  # If there isn't a vmdb_object_type yet just exit. The method will be recalled with an vmdb_object_type
  exit MIQ_OK unless $evm.root['vmdb_object_type']
  
  satellite_api = get_satellite_api()

  location_index = satellite_api.resource(:locations).call(:index)
  $evm.log(:info, "location_index => #{location_index}") if @DEBUG
  locations = Hash[ *location_index['results'].collect { |item| [item['id'], item['title']] }.flatten ]

  $evm.log(:info, "locations pre filtering: #{locations}") if @DEBUG
  dialog_field_values = {}
  locations.each do |location_id, location_name|
    tag_path = create_tag(TAG_CATEGORY, location_name)
    dialog_field_values[tag_path] = location_name
  end
  
  # remove location tags that are not tagged on a provider
  providers = $evm.vmdb(:ems).all
  dialog_field_values.delete_if do |id, name|
    provider_tagged      = false
    tag_name = to_tag_name(name)
    
    providers.each do |provider|
      provider_tagged = provider.tagged_with?(TAG_CATEGORY, tag_name)
      $evm.log(:info, "Provider '#{provider.name}' tagged with: #{TAG_CATEGORY} => #{tag_name}") if @DEBUG && provider_tagged
      break if provider_tagged
    end
    $evm.log(:info, "No provider tagged with: #{TAG_CATEGORY} => #{tag_name}") if @DEBUG && !provider_tagged
    
    !provider_tagged
  end
  dialog_field_values[nil] = '<Choose>'
  
  return_dialog_element(true, dialog_field_values)
end
