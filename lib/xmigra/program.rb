require 'xmigra'

module XMigra
  class Program
    ILLEGAL_PATH_CHARS = "\"<>:|"
    ILLEGAL_FILENAME_CHARS = ILLEGAL_PATH_CHARS + "/\\"
    
    class TerminatingOption < Exception; end
    class ArgumentError < XMigra::Error; end
    module QuietError; end
    
    class << self
      def subcommand(name, description, &block)
        (@subcommands ||= {})[name] = block
        (@subcommand_descriptions ||= {})[name] = description
      end
      
      # Run the given command line.
      # 
      # An array of command line arguments may be given as the only argument
      # or arguments may be given as call parameters.  Returns nil if the
      # command completed or a TerminatingOption object if a terminating
      # option (typically "--help") was passed.
      def run(*argv)
        options = (Hash === argv.last) ? argv.pop : {}
        argv = argv[0] if argv.length == 1 && Array === argv[0]
        prev_subcommand = @active_subcommand
        begin
          @active_subcommand = subcmd = argv.shift
          
          begin
            if subcmd == "help" || subcmd.nil?
              help(argv)
              return
            end
            
            begin
              (@subcommands[subcmd] || method(:show_subcommands_as_help)).call(argv)
            rescue StandardError => error
              raise unless options[:error]
              options[:error].call(error)
            end
          rescue TerminatingOption => stop
            return stop
          rescue Plugin::LoadingError => error
            $stderr.puts error.message
            exit 1
          end
        ensure
          @active_subcommand = prev_subcommand
        end
      end
      
      def help(argv)
        if (argv.length != 1) || (argv[0] == '--help')
          show_subcommands
          return
        end
        
        argv << "--help"
        run(argv)
      end
      
      def show_subcommands(_1=nil)
        puts
        puts "Use '#{File.basename($0)} help <subcommand>' for help on one of these subcommands:"
        puts
        
        descs = @subcommand_descriptions
        cmd_width = descs.enum_for(:each_key).max_by {|i| i.length}.length + 2
        descs.each_pair do |cmd, description|
          printf("%*s - ", cmd_width, cmd)
          description.lines.each_with_index do |line, i|
            indent = if (i > 0)..(i == description.lines.count - 1)
              cmd_width + 3
            else
              0
            end
            puts(" " * indent + line.chomp)
          end
        end
      end
      
      def show_subcommands_as_help(_1=nil)
        show_subcommands
        raise ArgumentError.new("Invalid subcommand").extend(QuietError)
      end
      
      def command_line(argv, use, cmdopts = {})
        options = OpenStruct.new
        argument_desc = cmdopts[:argument_desc]
        
        optparser = OptionParser.new do |flags|
          subcmd = @active_subcommand || "<subcmd>"
          flags.banner = [
            "Usage: #{File.basename($0)} #{subcmd} [<options>]",
            argument_desc
          ].compact.join(' ')
          flags.banner << "\n\n" + cmdopts[:help].chomp if cmdopts[:help]
          
          flags.separator ''
          flags.separator 'Subcommand options:'
          
          if use[:target_type]
            options.target_type = :unspecified
            allowed = [:exact, :substring, :regexp]
            flags.on(
              "--by=TYPE", allowed,
              "Specify how TARGETs are matched",
              "against subject strings",
              "(#{allowed.collect {|i| i.to_s}.join(', ')})"
            ) do |type|
              options.target_type = type
            end
          end
          
          if use[:dev_branch]
            options.dev_branch = false
            flags.on("--dev-branch", "Favor development branch usage assumption") do
              options.dev_branch = true
            end
          end
          
          unless use[:edit].nil?
            options.edit = use[:edit] ? true : false
            flags.banner << "\n\n" << (<<END_OF_HELP).chomp
When opening an editor, the program specified by the environment variable
VISUAL is preferred, then the one specified by EDITOR.  If neither of these
environment variables is set no editor will be opened.
END_OF_HELP
            flags.on("--[no-]edit", "Open the resulting file in an editor",
                     "(defaults to #{options.edit})") do |v|
              options.edit = %w{EDITOR VISUAL}.any? {|k| ENV.has_key?(k)} && v
            end
          end
          
          if use[:search_type]
            options.search_type = :changes
            allowed = [:changes, :sql]
            flags.on(
              "--match=SUBJECT", allowed,
              "Specify the type of subject against",
              "which TARGETs match",
              "(#{allowed.collect {|i| i.to_s}.join(', ')})"
            ) do |type|
              options.search_type = type
            end
          end
          
          if use[:outfile]
            options.outfile = nil
            flags.on("-o", "--outfile=FILE", "Output to FILE") do |fpath|
              options.outfile = File.expand_path(fpath)
            end
          end
          
          if use[:production]
            options.production = false
            flags.on("-p", "--production", "Generate script for production databases") do 
              options.production = true
            end
          end
          
          options.source_dir = Dir.pwd
          flags.on("--source=DIR", "Work from/on the schema in DIR") do |dir|
            options.source_dir = File.expand_path(dir)
          end
          
          flags.on_tail("-h", "--help", "Show this message") do
            puts
            puts flags
            raise TerminatingOption.new('--help')
          end
        end
        
        argv = optparser.parse(argv)
        
        if use[:target_type] && options.target_type == :unspecified
          options.target_type = case options.search_type
          when :changes then :strict
          else :substring
          end
        end
        
        return argv, options
      end
      
      def output_to(fpath_or_nil)
        if fpath_or_nil.nil?
          yield($stdout)
        else
          File.open(fpath_or_nil, "w") do |stream|
            yield(stream)
          end
        end
      end
      
      def argument_error_unless(test, message)
        return if test
        raise ArgumentError, XMigra.program_message(message, :cmd=>@active_subcommand)
      end
      
      def edit(fpath)
        case
        when (editor = ENV['VISUAL']) && PLATFORM == :mswin
          system(%Q{start #{editor} "#{fpath}"})
        when editor = ENV['VISUAL']
          system(%Q{#{editor} "#{fpath}" &})
        when editor = ENV['EDITOR']
          system(%Q{#{editor} "#{fpath}"})
        end
      end
    end
    
    subcommand 'overview', "Explain usage of this tool" do |argv|
      argument_error_unless([[], ["-h"], ["--help"]].include?(argv),
                            "'%prog %cmd' does not accept arguments.")
      
      formalizations = {
        /xmigra/i=>'XMigra',
      }
      
      section = proc do |name, content|
        puts
        puts name
        puts "=" * name.length
        puts XMigra.program_message(
          content,
          :prog=>/%program_cmd\b/
        )
      end
      
      puts XMigra.program_message(<<END_HEADER) # Overview

===========================================================================
# Usage of %program_name
===========================================================================
END_HEADER
      
      begin; section['Introduction', <<END_SECTION]

%program_name is a tool designed to assist development of software using
relational databases for persistent storage.  During the development cycle, this
tool helps manage:

  - Migration of production databases to newer versions, including migration
    between parallel, released versions.
  
  - Using transactional scripts, so that unexpected database conditions do not
    lead to corrupt production databases.
  
  - Protection of production databases from changes still under development.
  
  - Parallel development of features requiring database changes.
  
  - Assignment of permissions to database objects.

To accomplish this, the database schema to be created is decomposed into
several parts and formatted in text files according to certain rules.  The
%program_name tool is then used to manipulate, query, or generate scripts from
the set of files.
END_SECTION
      end
      begin; section['Schema Files and Folders', <<END_SECTION]

    SCHEMA (root folder/directory of decomposed schema)
    +-- database.yaml
    +-- permissions.yaml (optional)
    +-- structure
    |   +-- head.yaml
    |   +-- <migration files>
    |   ...
    +-- access
    |   +-- <stored procedure definition files>
    |   +-- <view definition files>
    |   +-- <user defined function definition files>
    |   ...
    +-- indexes
        +-- <index definition files>
        ...

  --------------------------------------------------------------------------
  NOTE: In case-sensitive filesystems, all file and directory names dictated
  by %program_name are lowercase.
  --------------------------------------------------------------------------

All data files used by %program_name conform to the YAML 1.0 data format
specification.  Please refer to that specification for information
on the specifics of encoding particular values.  This documentation, at many
points, makes reference to "sections" of a .yaml file; such a section is,
technically, an entry in the mapping at the top level of the .yaml file with
the given key.  The simplest understanding of this is that the section name
followed immediately (no whitespace) by a colon (':') and at least one space
character appears in the left-most column, and the section contents appear
either on the line after the colon-space or in an indented block starting on
the next line (often used with a scalar block indicator ('|' or '>') following
the colon-space).

The decomposed database schema lives within a filesystem subtree rooted at a
single folder (i.e. directory).  For examples in this documentation, that
folder will be called SCHEMA.  Two important files are stored directly in the
SCHEMA directory: database.yaml and permissions.yaml.  The "database.yaml" file
provides general information about the database for which scripts are to be
generated.  Please see the section below detailing this file's contents for
more information.  The "permissions.yaml" file specifies permissions to be
granted when generating a permission-granting script (run
'%program_cmd help permissions' for more information).

Within the SCHEMA folder, %program_name expects three other folders: structure,
access, and indexes.
END_SECTION
      end
      begin; section['The "SCHEMA/structure" Folder', <<END_SECTION]

Every relational database has structures in which it stores the persistent
data of the related application(s).  These database objects are special in
relation to other parts of the database because they contain information that
cannot be reproduced just from the schema definition.  Yet bug fixes and
feature additions will need to update this structure and good programming
practice dictates that such changes, and the functionalities relying on them,
need to be tested.  Testability, in turn, dictates a repeatable sequence of
actions to be executed on the database starting from a known state.

%program_name models the evolution of the persistent data storage structures
of a database as a chain of "migrations," each of which makes changes to the
database storage structure from a previous, known state of the database.  The
first migration starts at an empty database and each subsequent migration
starts where the previous migration left off.  Each migration is stored in
a file within the SCHEMA/structure folder.  The names of migration files start
with a date (YYYY-MM-DD) and include a short description of the change.  As
with other files used by the %program_name tool, migration files are in the
YAML format, using the ".yaml" extension.  Because some set of migrations
will determine the state of production databases, migrations themselves (as
used to produce production upgrade scripts) must be "set in stone" -- once
committed to version control (on a production branch) they must never change
their content.

Migration files are usually generated by running the '%program_cmd new'
command (see '%program_cmd help new' for more information) and then editing
the resulting file.  The migration file has several sections: "starting from",
"sql", "changes", and "description".  The "starting from" section indicates the
previous migration in the chain (or "empty database" for the first migration).
SQL code that effects the migration on the database is the content of the "sql"
section (usually given as a YAML literal block).  The "changes" section
supports '%program_cmd history', allowing a more user-friendly look at the
evolution of a subset of the database structure over the migration chain.
Finally, the "description" section is intended for a prose description of the
migration, and is included in the upgrade metadata stored in the database.  Use
of the '%program_cmd new' command is recommended; it handles several tiresome
and error-prone tasks: creating a new migration file with a conformant name,
setting the "starting from" section to the correct value, and updating
SCHEMA/structure/head.yaml to reference the newly generated file.

The SCHEMA/structure/head.yaml file deserves special note: it contains a
reference to the last migration to be applied.  Because of this, parallel
development of database changes will cause conflicts in the contents of this
file.  This is by design, and '%program_cmd unbranch' will assist in resolving
these conflicts.

Care must be taken when committing migration files to version control; because
the structure of production databases will be determined by the chain of
migrations (starting at an empty database, going up to some certain point),
it is imperative that migrations used to build these production upgrade scripts
not be modified once committed to the version control system.  When building
a production upgrade script, %program_name verifies that this constraint is
followed.  Therefore, if the need arises to commit a migration file that may
require amendment, the best practice is to commit it to a development branch.

Migrating a database from one released version (which may receive bug fixes
or critical feature updates) to another released version which developed along
a parallel track is generally a tricky endeavor.  Please see the section on
"branch upgrades" below for information on how %program_name supports this
use case.
END_SECTION
      end
      begin; section['The "SCHEMA/access" Folder', <<END_SECTION]

In addition to the structures that store persistent data, many relational
databases also support persistent constructs for providing consistent access
(creation, retrieval, update, and deletion) to the persistent data even as the
actual storage structure changes, allowing for a degree of backward
compatibility with applications.  These constructs do not, of themselves,
contain persistent data, but rather specify procedures for accessing the
persistent data.

In %program_name, such constructs are defined in the SCHEMA/access folder, with
each construct (usually) having its own file.  The name of the file must be
a valid SQL name for the construct defined.  The filename may be accessed
within the definition by the filename metavariable, by default "[{filename}]"
(without quotation marks); this assists renaming such constructs, making the
operation of renaming the construct a simple rename of the containing file
within the filesystem (and version control repository).  Use of files in this
way creates a history of each "access object's" definition in the version
control system organized by the name of the object.

The definition of the access object is given in the "sql" section of the
definition file, usually with a YAML literal block.  This SQL MUST define the
object for which the containing file is named; failure to do so will result in
failure of the script when it is run against the database.  After deleting
all access objects previously created by %program_name, the generated script
first checks that the access object does not exist, then runs the definition
SQL, and finally checks that the object now exists.

In addition to the SQL definition, %program_name needs to know what kind of
object is to be created by this definition.  This information is presented in
the "define" section, and is currently limited to "function",
"stored procedure", and "view".

Some database management systems enforce a rule that statements defining access
objects (or at least, some kinds of access objects) may not reference access
objects that do not yet exist.  (A good example is Microsoft SQL Server's rule
about user defined functions that means a definition for the function A may
only call the user defined function B if B exists when A is defined.)  To
accommodate this situation, %program_name provides an optional "referencing"
section in the access object definition file.  The content of this section
must be a YAML sequence of scalars, each of which is the name of an access
object file (the name must be given the same way the filename is written, not
just a way that is equivalent in the target SQL language).  The scalar values
must be appropriately escaped as necessary (e.g. Microsoft SQL Server uses
square brackets as a quotation mechanism, and square brackets have special
meaning in YAML, so it is necessary use quoted strings or a scalar block to
contain them).  Any access objects listed in this way will be created before
the referencing object.
END_SECTION
      end
      begin; section['The "SCHEMA/indexes" Folder', <<END_SECTION]

Database indexes vary from the other kinds of definitions supported by
%program_name: while SCHEMA/structure elements only hold data and
SCHEMA/access elements are defined entirely by their code in the schema and
can thus be efficiently re-created, indexes have their whole definition in
the schema, but store data gleaned from the persistent data.  Re-creation of
an index is an expensive operation that should be avoided when unnecessary.

To accomplish this end, %program_name looks in the SCHEMA/indexes folder for
index definitions.  The generated scripts will drop and (re-)create only
indexes whose definitions are changed.  %program_name uses a very literal
comparison of the SQL text used to create the index to determine "change;"
even so much as a single whitespace added or removed, even if insignificant to
the database management system, will be enough to cause the index to be dropped
and re-created.

Index definition files use only the "sql" section to provide the SQL definition
of the index.  Index definitions do not support use of the filename
metavariable because renaming an index would cause it to be dropped and
re-created.
END_SECTION
      end
      begin; section['The "SCHEMA/database.yaml" File', <<END_SECTION]

The SCHEMA/database.yaml file consists of several sections that provide general
information about the database schema.  The following subsections detail some
contents that may be included in this file.

system
------

The "system" section specifies for %program_name which database management
system shall be targeted for the generation of scripts.  Currently the
supported values are:

  - Microsoft SQL Server
  - PostgreSQL

Each system can also have sub-settings that modify the generated scripts.

  Microsoft SQL Server:
    The "MSSQL 2005 compatible" setting in SCEMA/database.yaml, if set to
    "true", causes INSERT statements to be generated in a more verbose and
    SQL Server 2005 compatible manner.

Also, each system may modify in other ways the behavior of the generator or
the interpretation of the definition files:

  Microsoft SQL Server:
    The SQL in the definition files may use the "GO" metacommand also found in
    Microsoft SQL Server Management Studio and sqlcmd.exe.  This metacommand
    must be on a line by itself where used.  It should produce the same results
    as it would in MSSMS or sqlcmd.exe, except that the overall script is
    transacted.

script comment
--------------

The "script comment" section defines a body of SQL to be inserted at the top
of all generated scripts.  This is useful for including copyright information
in the resulting SQL.

filename metavariable
---------------------

The "filename metavariable" section allows the schema to override the filename
metavariable that is used for access object definitions.  The default value
is "[{filename}]" (excluding the quotation marks).  If that string is required
in one or more access object definitions, this section allows the schema to
dictate another value.

XMigra plugin
-------------

If given, this section/entry provides a name to require into the XMigra
program (see documentation on Ruby's Kernel#require), with the intention that
the required file will define and activate an instance of a subclass of
XMigra::Plugin (see the documentation for XMigra::Plugin or
lib/xmigra/plugin.rb).  Only one plugin may be specified, though that one
plugin may aggregate the functionality of other plugins.

Plugins are an advanced feature that can defeat many of the measures %program_name
takes to guarantee that a database generated from scratch will go through the
same sequence of changes as the production database(s) has/have.  This can
happen even unintentionally, for instance by upgrading the gem that provides
the plugin.  While the resulting script will still (if possible) be transacted,
the incompatibility may not be discovered until the script is run against a
production database, requiring cancellation of deployment.  Use this feature
with extreme caution.
END_SECTION
      end
      begin; section['Script Generation Modes', <<END_SECTION]

%program_name supports two modes of upgrade script creation: development and
production.  (Permission script generation is not constrained to these modes.)
Upgrade script generation defaults to development mode, which does less
work to generate a script and skips tests intended to ensure that the script
could be generated again at some future point from the contents of the version
control repository.  The resulting script can only be run on an empty database
or a database that was set up with a development mode script earlier on the
same migration chain; running a development mode script on a database created
with a production script fails by design (preventing a production database from
undergoing a migration that has not been duly recorded in the version control
system).  Development scripts have a big warning comment at the beginning of
the script as a reminder that they are not suitable to use on a production
system.

Use of the '--production' flag with the '%program_cmd upgrade' command
enables production mode, which carries out a significant number of
additional checks.  These checks serve two purposes: making sure that all
migrations to be applied to a production database are recorded in the version
control system and that all of the definition files in the whole schema
represent a single, coherent point in the version history (i.e. all files are
from the same revision).  Where a case arises that a script needs to be
generated that cannot meet these two criteria, it is almost certainly a case
that calls for a development script.  There is always the option of creating
a new production branch and committing the %program_name schema files to that
branch if a production script is needed, thus meeting the criteria of the test.

Note that "development mode" and "production mode" are not about the quality
of the scripts generated or the "build mode" of the application that may access
the resulting database, but rather about the designation of the database
to which the generated scripts may be applied.  "Production" scripts certainly
should be tested in a non-production environment before they are applied to
a production environment with irreplaceable data.  But "development" scripts,
by design, can never be run on production systems (so that the production
systems only move from one well-documented state to another).
END_SECTION
      end
      begin; section['Branch Upgrades', <<END_SECTION]

Maintaining a single, canonical chain of database schema migrations released to
customers dramatically reduces the amount of complexity inherent in
same-version product upgrades.  But expecting development and releases to stay
on a single migration chain is overly optimistic; there are many circumstances
that lead to divergent migration chains across instances of the database.  A
bug fix on an already released version or some emergency feature addition for
an enormous profit opportunity are entirely possible, and any database
evolution system that breaks under those requirements will be an intolerable
hinderance.

%program_name supports these situations through the mechanism of "branch
upgrades."  A branch upgrade is a migration containing SQL commands to effect
the conversion of the head of the current branch's migration chain (i.e. the
state of the database after the most recent migration in the current branch)
into some state along another branch's migration chain.  These commands are not
applied when the upgrade script for this branch is run.  Rather, they are saved
in the database and run only if, and then prior to, an upgrade script for the
targeted branch is run against the same database.

Unlike regular migrations, changes to the branch upgrade migration MAY be
committed to the version control repository.

::::::::::::::::::::::::::::::::::: EXAMPLE :::::::::::::::::::::::::::::::::::
::                                                                           ::

Product X is about to release version 2.0.  Version 1.4 of Product X has
been in customers' hands for 18 months and seven bug fixes involving database
structure changes have been implemented in that time.  Our example company has
worked out the necessary SQL commands to convert the current head of the 1.4
migration chain to the same resulting structure as the head of the 2.0
migration chain.  Those SQL commands, and the appropriate metadata about the
target branch (version 2.0), the completed migration (the one named as the head
of the 2.0 branch), and the head of the 1.4 branch are all put into the
SCHEMA/structure/branch-upgrade.yaml file as detailed below.  %program_name
can then script the storage of these commands into the database for execution
by a Product X version 2.0 upgrade script.

Once the branch-upgrade.yaml file is created and committed to version control
in the version 1.4 branch, two upgrade scripts need to be generated: a
version 1.4 upgrade script and a version 2.0 upgrade script, each from its
respective branch in version control.  For each version 1.4 installation, the
1.4 script will first be run, bringing the installation up to the head of
version 1.4 and installing the instructions for upgrading to a version 2.0
database.  Then the version 2.0 script will be run, which will execute the
stored instructions for bringing the database from version 1.4 to version 2.0.

Had the branch upgrade not brought the version 1.4 database all the way up to
the head of version 2.0 (i.e. if the YAML file indicates a completed migration
prior to the version 2.0 head), the version 2.0 script would then apply any
following migrations in order to bring the database up to the version 2.0 head.

::                                                                           ::
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

In addition to the "sql" section, which has the same function as the "sql"
section of a regular migration, the SCHEMA/structure/branch-upgrade.yaml file
has three other required sections.

starting from
-------------

As with regular migrations, the branch-upgrade.yaml specifies a "starting from"
point, which should always be the head migration of the current branch (see
SCHEMA/structure/head.yaml).  If this section does not match with the latest
migration in the migration chain, no branch upgrade information will be
included in the resulting upgrade script and a warning will be issued during
script generation.  This precaution prevents out-of-date branch upgrade
commands from being run.

resulting branch
----------------

The "resulting branch" section must give the identifier of the branch
containing the migration chain into which the included SQL commands will
migrate the current chain head.  This identifier can be obtained with the
'%program_cmd branchid' command run against a working copy of the
target branch.

completes migration to
----------------------

Because the migration chain of the target branch is likely to be extended over
time, it is necessary to pin down the intended result state of the branch
upgrade to one particular migration in the target chain.  The migration name
listed in the "completes migration to" section should be the name of the
migration (the file basename) which brings the target branch database to the
same state as the head state of the current branch  after applying the
branch upgrade commands.
END_SECTION
      end
      puts
    end
    
    subcommand 'init', "Interactively set up a source filesystem subtree" do |argv|
      args, options = command_line(argv, {:edit=>true},
                                   :help=> <<END_OF_HELP)
This command interactively asks for and records the information needed to set
up a filesystem subtree as a source for generating scripts.
END_OF_HELP
      
      tool = SourceTreeInitializer.new(options.source_dir).extend(WarnToStderr)
      
      file_paths = tool.create_files!
      
      if options.edit
        file_paths.each {|fpath| edit(fpath)}
      end
    end
    
    subcommand 'new', "Create a new migration file" do |argv|
      args, options = command_line(argv, {:edit=>true},
                                   :argument_desc=>"MIGRATION_SUMMARY",
                                   :help=> <<END_OF_HELP)
This command generates a new migration file and ties it into the current
migration chain.  The name of the new file is generated from today's date and
the given MIGRATION_SUMMARY.  The resulting new file may be opened in an
editor (see the --[no-]edit option).
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      migration_summary = args[0]
      argument_error_unless(
        migration_summary.chars.all? {|c| !ILLEGAL_FILENAME_CHARS.include?(c)},
        "Migration summary may not contain any of: " + ILLEGAL_FILENAME_CHARS
      )
      
      tool = NewMigrationAdder.new(options.source_dir).extend(WarnToStderr)
      new_fpath = tool.add_migration(migration_summary)
      
      edit(new_fpath) if options.edit
    end
    
    subcommand 'upgrade', "Generate an upgrade script" do |argv|
      args, options = command_line(argv, {:production=>true, :outfile=>true},
                                   :help=> <<END_OF_HELP)
Running this command will generate an update script from the source schema.
Generation of a production script involves more checks on the status of the
schema source files but produces a script that may be run on a development,
production, or empty database.  If the generated script is not specified for
production it may only be run on a development or empty database; it will not
run on production databases.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      sql_gen = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      sql_gen.load_plugin!
      sql_gen.production = options.production
      
      output_to(options.outfile) do |out_stream|
        out_stream.print(sql_gen.update_sql)
      end
    end
    
    subcommand 'reversions', "Generate a script file containing reversions" do |argv|
      args, options = command_line(argv, {:outfile=>true},
                                   :help=> <<END_OF_HELP)
This command generates a script file containing parts that can be run to
revert individual migrations in reverse of the order they are applied.  The
SQL for reverting the migration is taken from a file with the same basename
as the migration it reverts, but in the 'rollback' subfolder and with a
'.sql' extension.  The output file will not run as a viable script; a 
contiguous section starting at the first SQL command and terminating at a
migration boundary should be run.  Subsequent sections, consecutive with those
previously run, may also be run to further revert the database if necessary.

It may be helpful to execute the query:

    SELECT * FROM xmigra.last_applied_migrations ORDER BY "RevertOrder";

This query lists the migrations applied by the last upgrade script that was
run.
END_OF_HELP

      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      sql_gen = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      sql_gen.load_plugin!
      
      output_to(options.outfile) do |out_stream|
        out_stream.print(sql_gen.reversion_script)
      end
    end
    
    subcommand 'render', "Generate SQL script for an access object" do |argv|
      args, options = command_line(argv, {:outfile=>true},
                                   :argument_desc=>"ACCESS_OBJECT_FILE",
                                   :help=> <<END_OF_HELP)
This command outputs the creation script for the access object defined in the
file at path ACCESS_OBJECT_FILE, making any substitutions in the same way as
the update script generator.
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      argument_error_unless(File.exist?(args[0]),
                            "'%prog %cmd' must target an existing access object definition.")
      
      sql_gen = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      sql_gen.load_plugin!
      
      artifact = sql_gen.access_artifacts[args[0]] || sql_gen.access_artifacts.at_path(args[0])
      output_to(options.outfile) do |out_stream|
        out_stream.print(artifact.creation_sql)
      end
    end
    
    subcommand 'unbranch', "Fix a branched migration chain" do |argv|
      args, options = command_line(argv, {:dev_branch=>true},
                                   :help=> <<END_OF_HELP)
Use this command to fix a branched migration chain.  The need for this command
usually arises when code is pulled from the repository into the working copy.

Because this program checks that migration files are unaltered when building
a production upgrade script it is important to use this command only:

  A) after updating in any branch, or

  B) after merging into (including synching) a development branch

If used in case B, the resulting changes may make the migration chain in the
current branch ineligible for generating production upgrade scripts.  When the
development branch is (cleanly) merged back to the production branch it will
still be possible to generate a production upgrade script from the production
branch.  In case B the resulting script (generated in development mode) should
be thoroughly tested.

Because of the potential danger to a production branch, this command checks
the branch usage before executing.  Inherent branch usage can be set through
the 'productionpattern' command.  If the target working copy has not been
marked with a production-branch pattern, the branch usage is ambiguous and
this command makes the fail-safe assumption that the branch is used for
production.  This assumption can be overriden with the --dev-branch option.
Note that the --dev-branch option will NOT override the production-branch
pattern if one exists.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      conflict = tool.get_conflict_info
      
      unless conflict
        STDERR.puts("No conflict!")
        return
      end
      
      if conflict.scope == :repository
        if conflict.branch_use == :production
          STDERR.puts(<<END_OF_MESSAGE)

The target working copy is on a production branch.  Because fixing the branched
migration chain would require modifying a committed migration, this operation
would result in a migration chain incapable of producing a production upgrade
script, leaving this branch unable to fulfill its purpose.

END_OF_MESSAGE
          raise(XMigra::Error, "Branch use conflict")
        end
        
        dev_branch = (conflict.branch_use == :development) || options.dev_branch
        
        unless dev_branch
          STDERR.puts(<<END_OF_MESSAGE)

The target working copy is neither marked for production branch recognition
nor was the --dev-branch option given on the command line.  Because fixing the
branched migration chain would require modifying a committed migration, this
operation would result in a migration chain incapable of producing a production
upgrage which, because the usage of the working copy's branch is ambiguous, 
might leave this branch unable to fulfill its purpose.

END_OF_MESSAGE
          raise(XMigra::Error, "Potential branch use conflict")
        end
        
        if conflict.branch_use == :undefined
          STDERR.puts(<<END_OF_MESSAGE)

The branch of the target working copy is not marked with a production branch
recognition pattern.  The --dev-branch option was given to override the
ambiguity, but it is much safer to use the 'productionpattern' command to
permanently mark the schema so that production branches can be automatically
recognized.

END_OF_MESSAGE
          # Warning, not error
        end
      end
      
      conflict.fix_conflict!
    end
    
    subcommand 'productionpattern', "Set the recognition pattern for production branches" do |argv|
      args, options = command_line(argv, {},
                                   :argument_desc=>"PATTERN",
                                   :help=> <<END_OF_HELP)
This command sets the production branch recognition pattern for the schema.
The pattern given will determine whether this program treats the current
working copy as a production or development branch.  The PATTERN given
is a Ruby Regexp that is used to evaluate the branch identifier of the working
copy.  Each supported version control system has its own type of branch
identifier:

  Subversion: The path within the repository, starting with a slash (e.g.
              "/trunk", "/branches/my-branch", "/foo/bar%20baz")

If PATTERN matches the branch identifier, the branch is considered to be a
production branch.  If PATTERN does not match, then the branch is a development
branch.  Some operations (e.g. 'unbranch') are prevented on production branches
to avoid making the branch ineligible for generating production upgrade
scripts.

In specifying PATTERN, it is not necessary to escape Ruby special characters
(especially including the slash character), but special characters for the
shell or command interpreter need their usual escaping.  The matching algorithm
used for PATTERN does not require the match to start at the beginning of the
branch identifier; specify the anchor as part of PATTERN if desired.
END_OF_HELP
      
      argument_error_unless(args.length == 1,
                            "'%prog %cmd' takes one argument.")
      Regexp.compile(args[0])
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      
      tool.production_pattern = args[0]
    end
    
    subcommand 'branchid', "Print the branch identifier string" do |argv|
      args, options = command_line(argv, {},
                                   :help=> <<END_OF_HELP)
This command prints the branch identifier string to standard out (followed by
a newline).
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      tool = SchemaManipulator.new(options.source_dir).extend(WarnToStderr)
      
      puts tool.branch_identifier
    end
    
    subcommand 'history', "Show all SQL from migrations changing the target" do |argv|
      args, options = command_line(argv, {:outfile=>true, :target_type=>true, :search_type=>true},
                                   :argument_desc=>"TARGET [TARGET [...]]",
                                   :help=> <<END_OF_HELP)
Use this command to get the SQL run by the upgrade script that modifies any of
the specified TARGETs.  By default this command uses a full item match against
the contents of each item in each migration's "changes" key (i.e.
--by=exact --match=changes).  Migration SQL is printed in order of application
to the database.
END_OF_HELP
      
      argument_error_unless(args.length >= 1,
                            "'%prog %cmd' requires at least one argument.")
      
      target_matches = case options.target_type
      when :substring
        proc {|subject| args.any? {|a| subject.include?(a)}}
      when :regexp
        patterns = args.map {|a| Regexp.compile(a)}
        proc {|subject| patterns.any? {|pat| pat.match(subject)}}
      else
        targets = Set.new(args)
        proc {|subject| targets.include?(subject)}
      end
      
      criteria_met = case options.search_type
      when :sql
        proc {|migration| target_matches.call(migration.sql)}
      else
        proc {|migration| migration.changes.any? {|subject| target_matches.call(subject)}}
      end
      
      tool = SchemaUpdater.new(options.source_dir).extend(WarnToStderr)
      tool.load_plugin!
      
      output_to(options.outfile) do |out_stream|
        tool.migrations.each do |migration|
          next unless criteria_met.call(migration)
          
          out_stream << tool.sql_comment_block(File.basename(migration.file_path))
          out_stream << migration.sql
          out_stream << "\n" << tool.batch_separator if tool.respond_to? :batch_separator
          out_stream << "\n"
        end
      end
    end
	
    subcommand 'permissions', "Generate a permission assignment script" do |argv|
      args, options = command_line(argv, {:outfile=>true},
                                   :help=> <<END_OF_HELP)
This command generates and outputs a script that assigns permissions within
a database instance.  The permission information is read from the
permissions.yaml file in the schema root directory (the same directory in which
database.yaml resides) and has the format:

    dbo.MyTable:
      Alice: SELECT
      Bob:
        - SELECT
        - INSERT

(More specifically: The top-level object is a mapping whose scalar keys are
the names of the objects to be modified and whose values are mappings from
security principals to either a single permission or a sequence of
permissions.)  The file is in YAML format; use quoted strings if necessary
(e.g. for Microsoft SQL Server "square bracket escaping", enclose the name in
single or double quotes within the permissions.yaml file to avoid
interpretation of the square brackets as delimiting a sequence).

Before establishing the permissions listed in permissions.yaml, the generated
script first removes any permissions previously granted through use of an
XMigra permissions script.  To accomplish this, the script establishes a table
if it does not yet exist.  The code for this precedes the code to remove
previous permissions.  Thus, the resulting script has the sequence:

    - Establish permission tracking table (if not present)
    - Revoke all previously granted permissions (only those granted
      by a previous XMigra script)
    - Grant permissions indicated in permissions.yaml

To facilitate review of the script, the term "GRANT" is avoided except for
the statements granting the permissions laid out in the source file.
END_OF_HELP
      
      argument_error_unless(args.length == 0,
                            "'%prog %cmd' does not take any arguments.")
      
      sql_gen = PermissionScriptWriter.new(options.source_dir).extend(WarnToStderr)
      sql_gen.load_plugin!
      
      output_to(options.outfile) do |out_stream|
        out_stream.print(sql_gen.permissions_sql)
      end
    end
  end
end
