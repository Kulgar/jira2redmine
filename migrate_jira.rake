require 'rexml/document'
require 'active_record'
require 'yaml'
require File.expand_path('../../../config/environment', __FILE__) # Assumes that migrate_jira.rake is in lib/tasks/



module JiraMigration
  include REXML

  file = File.new('backup_jira.xml')
  doc = Document.new file
  $doc = doc

  CONF_FILE = "map_jira_to_redmine.yml"

  $MIGRATED_USERS_BY_NAME = {} # Maps the Jira username to the Redmine Rails User object

  def self.retrieve_or_create_ghost_user
    ghost = User.find_by_login('deleted-user')
    if ghost.nil?
      ghost = User.new({  :firstname => 'Deleted', 
                          :lastname => 'User',
                          :mail => 'deleted.user@example.com',
                          :password => 'deleteduser123' })
      ghost.login = 'deleted-user'
      ghost.lock # disable the user
    end
    ghost
  end

  # A dummy Redmine user to use in place of JIRA users who have been deleted.
  # This user is lazily migrated only if needed.
  $GHOST_USER = self.retrieve_or_create_ghost_user

  $MIGRATED_ISSUE_TYPES = {} 
  $MIGRATED_ISSUE_STATUS = {}
  $MIGRATED_ISSUE_PRIORITIES = {}

  $MIGRATED_ISSUE_TYPES_BY_ID = {} 
  $MIGRATED_ISSUE_STATUS_BY_ID = {}
  $MIGRATED_ISSUE_PRIORITIES_BY_ID = {}

  def self.get_all_options()
    # return all options 
    # Issue Type, Issue Status, Issue Priority
    ret = {}
    ret["types"] = self.get_jira_issue_types()
    ret["status"] = self.get_jira_status()
    ret["priorities"] = self.get_jira_priorities()

    return ret
  end

  def self.use_ghost_user
    # Migrate the ghost user, if we have not done so already
    if $GHOST_USER.new_record?
      puts "Creating ghost user to represent deleted JIRA users. Login name = #{$GHOST_USER.login}"
      $GHOST_USER.save!
      $GHOST_USER.reload
    end
    $GHOST_USER
  end

  def self.find_user_by_jira_name(jira_name)
    user = $MIGRATED_USERS_BY_NAME[jira_name]
    if user.nil?
      # User has not been migrated. Probably a user who has been deleted from JIRA.
      # Select or create the ghost user and use him instead.
      user = use_ghost_user
    end
    user
  end

  def self.get_list_from_tag(xpath_query)
    # Get a tag node and get all attributes as a hash
    ret = []
    $doc.elements.each(xpath_query) {|node| ret.push(node.attributes.rehash)}

    return ret
  end

  class BaseJira
    attr_reader :tag
    attr_accessor :new_record
    MAP = {}

    def map
      self.class::MAP
    end

    def initialize(node)
      @tag = node
    end

    def method_missing(key, *args)
      if key.to_s.start_with?("jira_")
        attr = key.to_s.sub("jira_", "")
        return @tag.attributes[attr]
      end
      puts "Method missing: #{key}"
      raise NoMethodError key
    end

    def run_all_redmine_fields
      ret = {}
      self.methods.each do |method_name|
        m = method_name.to_s
        if m.start_with?("red_")
          mm = m.to_s.sub("red_", "")
          ret[mm] = self.send(m)
        end
      end
      return ret
    end
    def migrate
      all_fields = self.run_all_redmine_fields()
      pp("Saving:", all_fields)
      record = self.retrieve
      if record
        record.update_attributes(all_fields)
      else
        record = self.class::DEST_MODEL.new all_fields
      end
      if self.respond_to?("before_save")
        self.before_save(record)
      end
      record.save!
      record.reload
      self.map[self.jira_id] = record
      self.new_record = record
      if self.respond_to?("post_migrate")
        self.post_migrate(record)
      end
      return record 
    end
    def retrieve
      self.class::DEST_MODEL.find_by_name(self.jira_id)
    end
  end

  class JiraProject < BaseJira
    DEST_MODEL = Project
    MAP = {}

    def retrieve
      self.class::DEST_MODEL.find_by_identifier(self.red_identifier)
    end
    def post_migrate(new_record)
      if !new_record.module_enabled?('issue_tracking')
        new_record.enabled_modules << EnabledModule.new(:name => 'issue_tracking')
      end
      $MIGRATED_ISSUE_TYPES.values.uniq.each do |issue_type|
        if !new_record.trackers.include?(issue_type)
          new_record.trackers << issue_type
        end
      end
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_name
      self.jira_name
    end
    def red_description
      self.jira_name
    end
    def red_identifier
      ret = self.jira_key.downcase
      return ret
    end
  end

  class JiraUser < BaseJira
    attr_accessor :jira_firstName, :jira_lastName, :jira_emailAddress
      
    DEST_MODEL = User
    MAP = {}

    def initialize(node)
      super
    end

    def retrieve
      # Check mail address first, as it is more likely to match across systems
      user = self.class::DEST_MODEL.find_by_mail(self.jira_emailAddress)
      if !user
        user = self.class::DEST_MODEL.find_by_login(self.red_login)
      end

      return user
    end

    def migrate
      super
      $MIGRATED_USERS_BY_NAME[self.jira_name] = self.new_record
    end

    # First Name, Last Name, E-mail, Password
    # here is the tranformation of Jira attributes in Redmine attribues
    def red_firstname()
      self.jira_firstName
    end
    def red_lastname
      self.jira_lastName
    end
    def red_mail
      self.jira_emailAddress
    end
    def red_password
      self.jira_name
    end
    def red_login
      self.jira_name
    end
    def before_save(new_record)
      new_record.login = red_login
    end
  end

  class JiraComment < BaseJira
    DEST_MODEL = Journal
    MAP = {}

    def initialize(node)
      super
      # get a body from a comment
      # comment can have the comment body as a attribute or as a child tag
      @jira_body = @tag.attributes["body"] || @tag.elements["body"].text
    end

    def jira_marker
      return "FROM JIRA: #{self.jira_id}\n"
    end
    def retrieve
      Journal.first(:conditions => "notes LIKE '#{self.jira_marker}%'")
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    def red_notes
      self.jira_marker + "\n" + @jira_body
    end
    def red_created_on
      DateTime.parse(self.jira_created)
    end
    def red_user
      # retrieving the Rails object
      JiraMigration.find_user_by_jira_name(self.jira_author)
    end
    def red_journalized
      # retrieving the Rails object
      JiraIssue::MAP[self.jira_issue]
    end
  end

  class JiraIssue < BaseJira
    DEST_MODEL = Issue
    MAP = {}
    #attr_reader :jira_id, :jira_key, :jira_project, :jira_reporter, 
    #            :jira_type, :jira_summary, :jira_assignee, :jira_priority
    #            :jira_resolution, :jira_status, :jira_created, :jira_resolutiondate
    attr_reader  :jira_description


    def initialize(node_tag)
      super
      @jira_description = @tag.elements["description"].text if @tag.elements["description"]
    end
    def jira_marker
      return "FROM JIRA: #{self.jira_key}\n"
    end
    def retrieve
      Issue.first(:conditions => "description LIKE '#{self.jira_marker}%'")
    end

    def red_project
      # needs to return the Rails Project object
      proj = self.jira_project
      JiraProject::MAP[proj]
    end
    def red_subject
      #:subject => encode(issue.title[0, limit_for(Issue, 'subject')]),
      self.jira_summary
    end
    def red_description
      dsc = self.jira_marker + "\n"
      if @jira_description
        dsc += @jira_description 
      else
        dsc += self.red_subject
      end
      return dsc
    end
    def red_priority
      name = $MIGRATED_ISSUE_PRIORITIES_BY_ID[self.jira_priority]
      return $MIGRATED_ISSUE_PRIORITIES[name]
    end
    def red_created_on
      Time.parse(self.jira_created)
    end
    def red_updated_on
      Time.parse(self.jira_updated)
    end
    def red_status
      name = $MIGRATED_ISSUE_STATUS_BY_ID[self.jira_status]
      return $MIGRATED_ISSUE_STATUS[name]
    end
    def red_tracker
      type_name = $MIGRATED_ISSUE_TYPES_BY_ID[self.jira_type]
      return $MIGRATED_ISSUE_TYPES[type_name]
    end
    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_reporter)
    end
    def red_assigned_to
      JiraMigration.find_user_by_jira_name(self.jira_assignee)
    end

  end

  class JiraAttachment < BaseJira
    DEST_MODEL = Attachment
    MAP = {}

    def retrieve
      self.class::DEST_MODEL.find_by_disk_filename(self.red_filename)
    end
    def before_save(new_record)
      new_record.container = self.red_container
      pp(new_record)
    end

    # here is the tranformation of Jira attributes in Redmine attribues
    #<FileAttachment id="10084" issue="10255" mimetype="image/jpeg" filename="Landing_Template.jpg" 
    #                created="2011-05-05 15:54:59.411" filesize="236515" author="emiliano"/>
    def red_filename
      self.jira_filename.gsub(/[^\w\.\-]/,'_')  # stole from Redmine: app/model/attachment (methods sanitize_filenanme)
    end
    def red_disk_filename 
      Attachment.disk_filename(self.jira_issue+self.jira_filename)
    end
    def red_content_type 
      self.jira_mimetype.to_s.chomp
    end
    def red_filesize 
      self.jira_filesize
    end

    def red_created_on
      DateTime.parse(self.jira_created)
    end
    def red_author
      JiraMigration.find_user_by_jira_name(self.jira_assignee)
    end
    def red_container
      JiraIssue::MAP[self.jira_issue]
    end
  end


  def self.parse_projects()
    # PROJECTS:
    # for project we need (identifies, name and description)
    # in exported data we have name and key, in Redmine name and descr. will be equal
    # the key will be the identifier
    projs = []
    $doc.elements.each('/*/Project') do |node|
      proj = JiraProject.new(node)
      projs.push(proj)
    end

    migrated_projects = {}
    projs.each do |p|
      #puts "Name and descr.: #{p.red_name} and #{p.red_description}"
      #puts "identifier: #{p.red_identifier}"
      migrated_projects[p.jira_id] = p
    end
    #puts migrated_projects
    return projs
  end

  def self.parse_users()
    users = []

    # For users in Redmine we need:
    # First Name, Last Name, E-mail, Password
    # In Jira, the fullname and email are property (a little more hard to get)
    #
    # We need to parse the following XML elements:
    # <OSUser id="123" name="john" passwordHash="asdf..."/>
    #
    # <OSPropertyEntry id="234" entityName="OSUser" entityId="123" propertyKey="fullName" type="5"/>
    # <OSPropertyString id="234" values="John Smith"
    #
    # <OSPropertyEntry id="345" entityName="OSUser" entityId="123" propertyKey="email" type="5"/>
    # <OSPropertyString id="345" value="john.smith@gmail.com"/>

    $doc.elements.each('/*/OSUser') do |node|
      user = JiraUser.new(node)

      # Set user names (first name, last name)
      full_name = find_user_full_name(user.jira_id)
      unless full_name.nil?
        user.jira_firstName = full_name.split[0]
        user.jira_lastName = full_name.split[-1]
      end

      # Set email address
      user.jira_emailAddress = find_user_email_address(user.jira_id)

      users.push(user)
      puts "Found JIRA user: #{user.jira_firstName} #{user.jira_lastName}, email=#{user.jira_emailAddress}, username=#{user.jira_name}"
    end

    return users
  end

  def self.find_user_full_name(user_id)
    self.find_user_property_string(user_id, 'fullName')
  end

  def self.find_user_email_address(user_id)
    self.find_user_property_string(user_id, 'email')
  end

  def self.find_user_property_string(user_id, property_key)
    property_id = $doc.elements["/*/OSPropertyEntry[@entityName='OSUser'][@entityId='#{user_id}'][@propertyKey='#{property_key}']"].attributes["id"]
    $doc.elements["/*/OSPropertyString[@id='#{property_id}']"].attributes["value"]
  end

  ISSUE_TYPE_MARKER = "(choose a Redmine Tracker)"
  DEFAULT_ISSUE_TYPE_MAP = {
    # Default map from Jira (key) to Redmine (value)
    # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
    "Bug" => "Bug",              # A problem which impairs or prevents the functions of the product.
    "Improvement" => "Feature",  # An enhancement to an existing feature.
    "New Feature" => "Feature",  # A new feature of the product.
    "Task" => "Task",            # A task that needs to be done.
    "Custom Issue" => "Support", # A custom issue type, as defined by your organisation if required.
  }
  def self.get_jira_issue_types()
    # Issue Type
    issue_types = self.get_list_from_tag('/*/IssueType') 
    #migrated_issue_types = {"jira_type" => "redmine tracker"}
    migrated_issue_types = {}
    issue_types.each do |issue|
      migrated_issue_types[issue["name"]] = DEFAULT_ISSUE_TYPE_MAP.fetch(issue["name"], ISSUE_TYPE_MARKER)
      $MIGRATED_ISSUE_TYPES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_types
  end

  ISSUE_STATUS_MARKER = "(choose a Redmine Issue Status)"
  DEFAULT_ISSUE_STATUS_MAP = {
    # Default map from Jira (key) to Redmine (value)
    # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
    "Open" => "New",                # This issue is in the initial 'Open' state, ready for the assignee to start work on it.
    "In Progress" => "In Progress", # This issue is being actively worked on at the moment by the assignee.
    "Resolved" => "Resolved",       # A Resolution has been identified or implemented, and this issue is awaiting verification by the reporter. From here, issues are either 'Reopened' or are 'Closed'.
    "Reopened" => "Assigned",       # This issue was once 'Resolved' or 'Closed', but is now being re-examined. (For example, an issue with a Resolution of 'Cannot Reproduce' is Reopened when more information becomes available and the issue becomes reproducible). From here, issues are either marked In Progress, Resolved or Closed.
    "Closed" => "Closed",           # This issue is complete. ## Be careful to choose one which a "issue closed" attribute marked :-)
  }
  def self.get_jira_status()
    # Issue Status
    issue_status = self.get_list_from_tag('/*/Status') 
    migrated_issue_status = {}
    issue_status.each do |issue|
      migrated_issue_status[issue["name"]] = DEFAULT_ISSUE_STATUS_MAP.fetch(issue["name"], ISSUE_STATUS_MARKER)
      $MIGRATED_ISSUE_STATUS_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_status
  end

  ISSUE_PRIORITY_MARKER = "(choose a Redmine Enumeration Issue Priority)"
  DEFAULT_ISSUE_PRIORITY_MAP = {
    # Default map from Jira (key) to Redmine (value)
    # the comments on right side are Jira definitions - http://confluence.atlassian.com/display/JIRA/What+is+an+Issue#
     "Blocker" => "Immediate", # Highest priority. Indicates that this issue takes precedence over all others.
     "Critical" => "Urgent",   # Indicates that this issue is causing a problem and requires urgent attention.
     "Major" => "High",        # Indicates that this issue has a significant impact.
     "Minor" => "Normal",      # Indicates that this issue has a relatively minor impact.
     "Trivial" => "Low",       # Lowest priority.
  }
  def self.get_jira_priorities()
    # Issue Priority
    issue_priority = self.get_list_from_tag('/*/Priority') 
    migrated_issue_priority = {}
    issue_priority.each do |issue|
      migrated_issue_priority[issue["name"]] = DEFAULT_ISSUE_PRIORITY_MAP.fetch(issue["name"], ISSUE_PRIORITY_MARKER)
      $MIGRATED_ISSUE_PRIORITIES_BY_ID[issue["id"]] = issue["name"]
    end
    return migrated_issue_priority
  end

  def self.parse_comments()
    ret = []
    $doc.elements.each('/*/Action[@type="comment"]') do |node|
      comment = JiraComment.new(node)
      ret.push(comment)
    end
    return ret
  end 

  def self.parse_issues()
    ret = []
    $doc.elements.each('/*/Issue') do |node|
      issue = JiraIssue.new(node)
      ret.push(issue)
    end
    return ret
  end 

  def self.parse_attachments()
    attachs = []
    $doc.elements.each('/*/FileAttachment') do |node|
      attach = JiraAttachment.new(node)
      attachs.push(attach)
    end

    return attachs
  end
end




namespace :jira_migration do

  desc "Generates the configuration for the map things from Jira to Redmine"
  task :generate_conf => :environment do
    conf_file = JiraMigration::CONF_FILE
    conf_exists = File.exists?(conf_file)
    if conf_exists
      puts "You already have a conf file"
      print "You want overwrite it ? [y/N] "
      overwrite = STDIN.gets.match(/^y$/i)
    end

    if !conf_exists or overwrite
      # Let's give the user all options to fill out
      options = JiraMigration.get_all_options()

      File.open(conf_file, "w"){ |f| f.write(options.to_yaml) }

      puts "This migration script needs the migration table to continue "
      puts "Please... fill the map table on the file: '#{conf_file}' and run again the script"
      puts "To start the options again, just remove the file '#{conf_file} and run again the script"
      exit(0)
    end
  end

  desc "Gets the configuration from YAML"
  task :pre_conf => :environment do
    conf_file = JiraMigration::CONF_FILE
    conf_exists = File.exists?(conf_file)

    if !conf_exists 
      Rake::Task['jira_migration:generate_conf'].invoke
    end
    $confs = YAML.load_file(conf_file)
  end

  desc "Tests all parsers!"
  task :test_all_migrations => [:environment, :pre_conf,
                              :test_parse_projects, 
                              :test_parse_users, 
                              :test_parse_comments, 
                              :test_parse_issues, 
                             ] do
    puts "All parsers was run! :-)"
  end

  desc "Tests all parsers!"
  task :do_all_migrations => [:environment, :pre_conf,
                              :migrate_issue_types, 
                              :migrate_issue_status, 
                              :migrate_issue_priorities, 
                              :migrate_projects, 
                              :migrate_users, 
                              :migrate_issues, 
                              :migrate_comments, 
                              :migrate_attachments,
                             ] do
    puts "All migrations done! :-)"
  end


  desc "Migrates Jira Issue Types to Redmine Trackes"
  task :migrate_issue_types => [:environment, :pre_conf] do

    JiraMigration.get_jira_issue_types()
    types = $confs["types"]
    types.each do |key, value|
      t = Tracker.find_or_create_by_name(value)
      t.save!
      t.reload
      $MIGRATED_ISSUE_TYPES[key] = t
    end
    puts "Migrated issue types"
  end

  desc "Migrates Jira Issue Status to Redmine Status"
  task :migrate_issue_status => [:environment, :pre_conf] do
    JiraMigration.get_jira_status()
    status = $confs["status"]
    status.each do |key, value|
      s = IssueStatus.find_or_create_by_name(value)
      s.save!
      s.reload
      $MIGRATED_ISSUE_STATUS[key] = s
    end
    puts "Migrated issue status"
  end

  desc "Migrates Jira Issue Priorities to Redmine Priorities"
  task :migrate_issue_priorities => [:environment, :pre_conf] do
    JiraMigration.get_jira_priorities()
    priorities = $confs["priorities"]

    priorities.each do |key, value|
      p = IssuePriority.find_or_create_by_name(value)
      p.save!
      p.reload
      $MIGRATED_ISSUE_PRIORITIES[key] = p
    end
    puts "Migrated issue priorities"
  end

  desc "Migrates Jira Projects to Redmine Projects"
  task :migrate_projects => :environment do
    projects = JiraMigration.parse_projects()
    projects.each do |p|
      #pp(p)
      p.migrate
    end
  end

  desc "Migrates Jira Users to Redmine Users"
  task :migrate_users => :environment do
    users = JiraMigration.parse_users()
    users.each do |u|
      #pp(u)
      u.migrate
    end
  end

  desc "Migrates Jira Issues to Redmine Issues"
  task :migrate_issues => :environment do
    issues = JiraMigration.parse_issues()
    issues.each do |i|
      #pp(i)
      i.migrate
    end
  end

  desc "Migrates Jira Issues Comments to Redmine Issues Journals (Notes)"
  task :migrate_comments => :environment do
    comments = JiraMigration.parse_comments()
    comments.each do |c|
      #pp(c)
      c.migrate
    end
  end

  desc "Migrates Jira Issues Attachments to Redmine Attachments"
  task :migrate_attachments => :environment do
    attachs = JiraMigration.parse_attachments()
    attachs.each do |a|
      #pp(c)
      a.migrate
    end
  end

  # Tests.....
  desc "Just pretty print Jira Projects on screen"
  task :test_parse_projects => :environment do
    projects = JiraMigration.parse_projects()
    projects.each {|p| pp(p.run_all_redmine_fields) }
  end

  desc "Just pretty print Jira Users on screen"
  task :test_parse_users => :environment do
    users = JiraMigration.parse_users()
    users.each {|u| pp( u.run_all_redmine_fields) }
  end

  desc "Just pretty print Jira Comments on screen"
  task :test_parse_comments => :environment do
    comments = JiraMigration.parse_comments()
    comments.each {|c| pp( c.run_all_redmine_fields) }
  end

  desc "Just pretty print Jira Issues on screen"
  task :test_parse_issues => :environment do
    issues = JiraMigration.parse_issues()
    issues.each {|i| pp( i.run_all_redmine_fields) }
  end
end
