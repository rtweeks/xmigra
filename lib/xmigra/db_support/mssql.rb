
module XMigra
  module MSSQLSpecifics
    DatabaseSupportModules << self
    
    SYSTEM_NAME = 'Microsoft SQL Server'
    
    IDENTIFIER_SUBPATTERN = '[a-z_@#][a-z0-9@$#_]*|"[^\[\]"]+"|\[[^\[\]]+\]'
    DBNAME_PATTERN = /^
      (?:(#{IDENTIFIER_SUBPATTERN})\.)?
      (#{IDENTIFIER_SUBPATTERN})
    $/ix
    STATISTICS_FILE = 'statistics-objects.yaml'
    
    ID_COLLATION = 'Latin1_General_CS_AS'
    
    class StatisticsObject
      def initialize(name, params)
        (@name = name.dup).freeze
        (@target = params[0].dup).freeze
        (@columns = params[1].dup).freeze
        @options = params[2] || {}
        @options.freeze
        @options.each_value {|v| v.freeze}
      end
      
      attr_reader :name, :target, :columns, :options
      
      def creation_sql
        result = "CREATE STATISTICS #{name} ON #{target} (#{columns})"
        
        result += " WHERE " + @options['where'] if @options['where']
        result += " WITH " + @options['with'] if @options['with']
        
        result += ";"
        return result
      end
    end
    
    def ddl_block_separator; "\nGO\n"; end
    def filename_metavariable; "[{filename}]"; end
    
    def stats_objs
      return @stats_objs if @stats_objs
      
      begin
        stats_data = YAML::load_file(path.join(MSSQLSpecifics::STATISTICS_FILE))
      rescue Errno::ENOENT
        return @stats_objs = [].freeze
      end
      
      @stats_objs = stats_data.collect {|item| StatisticsObject.new(*item)}
      @stats_objs.each {|o| o.freeze}
      @stats_objs.freeze
      
      return @stats_objs
    end
    
    def in_ddl_transaction
      parts = []
      parts << <<-"END_OF_SQL"
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

SET ANSI_PADDING ON
GO

SET NOCOUNT ON
GO

BEGIN TRY
  BEGIN TRAN;
      END_OF_SQL
      
      each_batch(yield) do |batch|
        batch_literal = MSSQLSpecifics.string_literal("\n" + batch)
        parts << "EXEC sp_executesql @statement = #{batch_literal};"
      end
      
      parts << <<-"END_OF_SQL"
  COMMIT TRAN;
END TRY
BEGIN CATCH
  ROLLBACK TRAN;
  
  DECLARE @ErrorMessage NVARCHAR(4000);
  DECLARE @ErrorSeverity INT;
  DECLARE @ErrorState INT;
  
  PRINT N'Update failed: ' + ERROR_MESSAGE();
  PRINT N'    State: ' + CAST(ERROR_STATE() AS NVARCHAR);
  PRINT N'    Line: ' + CAST(ERROR_LINE() AS NVARCHAR);

  SELECT 
      @ErrorMessage = N'Update failed: ' + ERROR_MESSAGE(),
      @ErrorSeverity = ERROR_SEVERITY(),
      @ErrorState = ERROR_STATE();

  -- Use RAISERROR inside the CATCH block to return error
  -- information about the original error that caused
  -- execution to jump to the CATCH block.
  RAISERROR (@ErrorMessage, -- Message text.
             @ErrorSeverity, -- Severity.
             @ErrorState -- State.
             );
END CATCH;
      END_OF_SQL
      
      return parts.join("\n")
    end
    
    def amend_script_parts(parts)
      parts.insert_after(
        :create_and_fill_indexes_table_sql,
        :create_and_fill_statistics_table_sql
      )
      parts.insert_after(
        :remove_undesired_indexes_sql,
        :remove_undesired_statistics_sql
      )
      parts.insert_after(:create_new_indexes_sql, :create_new_statistics_sql)
    end
    
    def check_execution_environment_sql
      <<-"END_OF_SQL"
PRINT N'Checking execution environment:';
IF DB_NAME() IN ('master', 'tempdb', 'model', 'msdb')
BEGIN
  RAISERROR(N'Please select an appropriate target database for the update script.', 11, 1);
END;
      END_OF_SQL
    end
    
    def ensure_version_tables_sql
      <<-"END_OF_SQL"
PRINT N'Ensuring version tables:';
IF NOT EXISTS (
  SELECT * FROM sys.schemas
  WHERE name = N'xmigra'
)
BEGIN
  EXEC sp_executesql N'
    CREATE SCHEMA [xmigra] AUTHORIZATION [dbo];
  ';
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[applied]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[applied] (
    [MigrationID]            nvarchar(80) COLLATE #{ID_COLLATION} NOT NULL,
    [ApplicationOrder]       int IDENTITY(1,1) NOT NULL,
    [VersionBridgeMark]      bit NOT NULL,
    [Description]            nvarchar(max) NOT NULL,
    
    CONSTRAINT [PK_version] PRIMARY KEY CLUSTERED (
      [MigrationID] ASC
    ) WITH (
      PAD_INDEX = OFF,
      STATISTICS_NORECOMPUTE  = OFF,
      IGNORE_DUP_KEY = OFF,
      ALLOW_ROW_LOCKS = ON,
      ALLOW_PAGE_LOCKS = ON
    ) ON [PRIMARY]
  ) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.columns
  WHERE object_id = OBJECT_ID(N'[xmigra].[applied]')
  AND name = N'MigrationID'
  AND collation_name = N'#{ID_COLLATION}'
)
BEGIN
  ALTER TABLE xmigra.applied DROP CONSTRAINT PK_version;
  ALTER TABLE xmigra.applied ALTER COLUMN [MigrationID] nvarchar(80) COLLATE Latin1_General_CS_AS NOT NULL;
  ALTER TABLE xmigra.applied ADD CONSTRAINT PK_version PRIMARY KEY ([MigrationID] ASC) WITH (
    PAD_INDEX = OFF,
    STATISTICS_NORECOMPUTE  = OFF,
    IGNORE_DUP_KEY = OFF,
    ALLOW_ROW_LOCKS = ON,
    ALLOW_PAGE_LOCKS = ON
  ) ON [PRIMARY];
END;

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[previous_states]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[previous_states] (
    [Changed]                   datetime NOT NULL,
    [MigrationApplicationOrder] int NOT NULL,
    [FromMigrationID]           nvarchar(80) COLLATE #{ID_COLLATION},
    [ToRangeStartMigrationID]   nvarchar(80) COLLATE #{ID_COLLATION} NOT NULL,
    [ToRangeEndMigrationID]     nvarchar(80) COLLATE #{ID_COLLATION} NOT NULL,
    
    CONSTRAINT [PK_previous_states] PRIMARY KEY CLUSTERED (
      [Changed] ASC,
      [MigrationApplicationOrder] ASC
    )
  );
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[DF_version_VersionBridgeMark]')
  AND type IN (N'D')
)
BEGIN
  ALTER TABLE [xmigra].[applied] ADD CONSTRAINT [DF_version_VersionBridgeMark]
    DEFAULT (0) FOR [VersionBridgeMark];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[access_objects]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[access_objects] (
    [type] nvarchar(40) NOT NULL,
    [name] nvarchar(256) NOT NULL,
    [order] int identity(1,1) NOT NULL,
    
    CONSTRAINT [PK_access_objects] PRIMARY KEY CLUSTERED (
      [name] ASC
    ) WITH (
      PAD_INDEX = OFF,
      STATISTICS_NORECOMPUTE  = OFF,
      IGNORE_DUP_KEY = OFF,
      ALLOW_ROW_LOCKS = ON,
      ALLOW_PAGE_LOCKS = ON
    ) ON [PRIMARY]
  ) ON [PRIMARY];
END;
GO

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[indexes]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[indexes] (
    [IndexID] nvarchar(80) NOT NULL PRIMARY KEY,
    [name] nvarchar(256) NOT NULL
  ) ON [PRIMARY];
END;

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[statistics]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[statistics] (
    [Name] nvarchar(100) NOT NULL PRIMARY KEY,
    [Columns] nvarchar(256) NOT NULL
  ) ON [PRIMARY];
END;

IF NOT EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[branch_upgrade]')
  AND type in (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[branch_upgrade] (
    [ApplicationOrder] int identity(1,1) NOT NULL,
    [Current] nvarchar(80) COLLATE #{ID_COLLATION} NOT NULL PRIMARY KEY,
    [Next] nvarchar(80) COLLATE #{ID_COLLATION} NULL,
    [UpgradeSql] nvarchar(max) NULL,
    [CompletesMigration] nvarchar(80) COLLATE #{ID_COLLATION} NULL
  ) ON [PRIMARY];
END;
GO
ALTER TABLE [xmigra].[branch_upgrade] ALTER COLUMN [CompletesMigration] nvarchar(80) COLLATE #{ID_COLLATION} NULL;

IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[last_applied_migrations]')
  AND type IN (N'V')
)
BEGIN
  DROP VIEW [xmigra].[last_applied_migrations];
END;
GO

CREATE VIEW [xmigra].[last_applied_migrations] AS
SELECT
  ROW_NUMBER() OVER (ORDER BY a.[ApplicationOrder] DESC) AS [RevertOrder],
  a.[Description]
FROM
  [xmigra].[applied] a
WHERE
  a.[ApplicationOrder] > COALESCE((
    SELECT TOP (1) ps.[MigrationApplicationOrder]
    FROM [xmigra].[previous_states] ps
    JOIN [xmigra].[applied] a2 ON ps.[ToRangeStartMigrationID] = a2.[MigrationID]
    ORDER BY ps.[Changed] DESC
  ), 0);
      END_OF_SQL
    end
    
    def create_and_fill_migration_table_sql
      intro = <<-"END_OF_SQL"
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[migrations]')
  AND type IN (N'U')
)
BEGIN
  DROP TABLE [xmigra].[migrations];
END;
GO

CREATE TABLE [xmigra].[migrations] (
  [MigrationID]            nvarchar(80) COLLATE #{ID_COLLATION} NOT NULL,
  [ApplicationOrder]       int NOT NULL,
  [Description]            ntext NOT NULL,
  [Install]                bit NOT NULL DEFAULT(0)
);
GO

      END_OF_SQL
      
      mig_insert = <<-"END_OF_SQL"
INSERT INTO [xmigra].[migrations] (
  [MigrationID],
  [ApplicationOrder],
  [Description]
) VALUES
      END_OF_SQL
      
      if (@db_info || {}).fetch('MSSQL 2005 compatible', false).eql?(true)
        parts = [intro]
        (0...migrations.length).each do |i|
          m = migrations[i]
          description_literal = MSSQLSpecifics.string_literal(m.description.strip)
          parts << mig_insert + "(N'#{m.id}', #{i + 1}, #{description_literal});\n"
        end
        return parts.join('')
      else
        return intro + mig_insert + (0...migrations.length).collect do |i|
          m = migrations[i]
          description_literal = MSSQLSpecifics.string_literal(m.description.strip)
          "(N'#{m.id}', #{i + 1}, #{description_literal})"
        end.join(",\n") + ";\n"
      end
    end
    
    def create_and_fill_indexes_table_sql
      intro = <<-"END_OF_SQL"
PRINT N'Creating and filling index manipulation table:';
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[updated_indexes]')
  AND type IN (N'U')
)
BEGIN
  DROP TABLE [xmigra].[updated_indexes];
END;
GO

CREATE TABLE [xmigra].[updated_indexes] (
  [IndexID]                  NVARCHAR(80) NOT NULL PRIMARY KEY
);
GO

      END_OF_SQL
      
      insertion = <<-"END_OF_SQL"
INSERT INTO [xmigra].[updated_indexes] ([IndexID]) VALUES
      END_OF_SQL
      
      strlit = MSSQLSpecifics.method :string_literal
      return intro + (insertion + indexes.collect do |index|
        "(#{strlit[index.id]})"
      end.join(",\n") + ";\n" unless indexes.empty?).to_s
    end
    
    def create_and_fill_statistics_table_sql
      intro = <<-"END_OF_SQL"
PRINT N'Creating and filling statistics object manipulation table:';
IF EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[updated_statistics]')
  AND type in (N'U')
)
BEGIN
  DROP TABLE [xmigra].[updated_statistics];
END;
GO

CREATE TABLE [xmigra].[updated_statistics] (
  [Name] nvarchar(100) NOT NULL PRIMARY KEY,
  [Columns] nvarchar(256) NOT NULL
);
GO

      END_OF_SQL
      
      insertion = <<-"END_OF_SQL"
INSERT INTO [xmigra].[updated_statistics] ([Name], [Columns]) VALUES
      END_OF_SQL
      
      strlit = MSSQLSpecifics.method :string_literal
      return intro + (insertion + stats_objs.collect do |stats_obj|
        "(#{strlit[stats_obj.name]}, #{strlit[stats_obj.columns]})"
      end.join(",\n") + ";\n" unless stats_objs.empty?).to_s
    end
    
    def check_preceding_migrations_sql
      parts = []
      
      parts << (<<-"END_OF_SQL") if production 
IF EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
) AND NOT EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
  WHERE #{branch_id_literal} IN ([Current], [Next])
)
RAISERROR (N'Existing database is from a different (and non-upgradable) branch.', 11, 1);

      END_OF_SQL
      
      parts << (<<-"END_OF_SQL")
IF NOT #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Checking preceding migrations:';
  -- Get the ApplicationOrder of the most recent version bridge migration
  DECLARE @VersionBridge INT;
  SET @VersionBridge = (
    SELECT COALESCE(MAX([ApplicationOrder]), 0)
    FROM [xmigra].[applied]
    WHERE [VersionBridgeMark] <> 0
  );
  
  -- Check for existence of applied migrations after the latest version
  -- bridge that are not in [xmigra].[migrations]
  IF EXISTS (
    SELECT * FROM [xmigra].[applied] a
    WHERE a.[ApplicationOrder] > @VersionBridge
    AND a.[MigrationID] NOT IN (
      SELECT m.[MigrationID] FROM [xmigra].[migrations] m
    )
  )
  RAISERROR (N'Unknown in-branch migrations have been applied.', 11, 1);
END;
      END_OF_SQL
      
      return parts.join('')
    end
    
    def check_chain_continuity_sql
      <<-"END_OF_SQL"
IF NOT #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Checking migration chain continuity:';
  -- Get the [xmigra].[migrations] ApplicationOrder of the most recent version bridge migration
  DECLARE @BridgePoint INT;
  SET @BridgePoint = (
    SELECT COALESCE(MAX(m.[ApplicationOrder]), 0)
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    WHERE a.[VersionBridgeMark] <> 0
  );
  
  -- Test for previously applied migrations that break the continuity of the
  -- migration chain in this script:
  IF EXISTS (
    SELECT *
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    INNER JOIN [xmigra].[migrations] p
      ON m.[ApplicationOrder] - 1 = p.[ApplicationOrder]
    WHERE p.[ApplicationOrder] > @BridgePoint
    AND p.[MigrationID] NOT IN (
      SELECT a2.[MigrationID] FROM [xmigra].[applied] a2
    )
  )
  BEGIN
    RAISERROR(
      N'Previously applied migrations interrupt the continuity of the migration chain',
      11,
      1
    );
  END;
END;
      END_OF_SQL
    end
    
    def select_for_install_sql
      <<-"END_OF_SQL"
PRINT N'Selecting migrations to apply:';
DECLARE @BridgePoint INT;
IF #{upgrading_to_new_branch_test_sql}
BEGIN
  -- Get the [xmigra].[migrations] ApplicationOrder of the record corresponding to the branch transition
  SET @BridgePoint = (
    SELECT MAX(m.[ApplicationOrder])
    FROM [xmigra].[migrations] m
    INNER JOIN [xmigra].[branch_upgrade] bu
      ON m.[MigrationID] = bu.[CompletesMigration]
  );
  
  UPDATE [xmigra].[migrations]
  SET [Install] = 1
  WHERE [ApplicationOrder] > @BridgePoint;
END
ELSE BEGIN
  -- Get the [xmigra].[migrations] ApplicationOrder of the most recent version bridge migration
  SET @BridgePoint = (
    SELECT COALESCE(MAX(m.[ApplicationOrder]), 0)
    FROM [xmigra].[applied] a
    INNER JOIN [xmigra].[migrations] m
      ON a.[MigrationID] = m.[MigrationID]
    WHERE a.[VersionBridgeMark] <> 0
  );
  
  UPDATE [xmigra].[migrations]
  SET [Install] = 1
  WHERE [MigrationID] NOT IN (
    SELECT a.[MigrationID] FROM [xmigra].[applied] a
  )
  AND [ApplicationOrder] > @BridgePoint;
END;

INSERT INTO [xmigra].[previous_states] (
  [Changed],
  [MigrationApplicationOrder],
  [FromMigrationID],
  [ToRangeStartMigrationID],
  [ToRangeEndMigrationID]
)
SELECT TOP (1)
  CURRENT_TIMESTAMP,
  -- Application order of last installed migration --
  COALESCE(
    ( 
      SELECT TOP(1) [ApplicationOrder] FROM [xmigra].[applied]
      ORDER BY [ApplicationOrder] DESC
    ),
    0
  ),
  ( -- Last installed migration --
    SELECT TOP (1) [MigrationID]
    FROM [xmigra].[applied]
    ORDER BY [ApplicationOrder] DESC
  ),
  m.[MigrationID],
  ( -- Last migration to install --
    SELECT TOP(1) [MigrationID] FROM [xmigra].[migrations]
    WHERE [Install] <> 0
    ORDER BY [ApplicationOrder] DESC
  )
FROM [xmigra].[migrations] m
WHERE m.[Install] <> 0
ORDER BY m.[ApplicationOrder] ASC;
      END_OF_SQL
    end
    
    def production_config_check_sql
      unless production
        id_literal = MSSQLSpecifics.string_literal(@migrations[0].id)
        <<-"END_OF_SQL"
PRINT N'Checking for production status:';
IF EXISTS (
  SELECT * FROM [xmigra].[migrations]
  WHERE [MigrationID] = #{id_literal}
  AND [Install] <> 0
)
BEGIN
  CREATE TABLE [xmigra].[development] (
    [info] nvarchar(200) NOT NULL PRIMARY KEY
  );
END;
GO

IF NOT EXISTS (
  SELECT * FROM [sys].[objects]
  WHERE object_id = OBJECT_ID(N'[xmigra].[development]')
  AND type = N'U'
)
RAISERROR(N'Development script cannot be applied to a production database.', 11, 1);
        END_OF_SQL
      end
    end
    
    def remove_access_artifacts_sql
      # Iterate the [xmigra].[access_objects] table and drop all access
      # objects previously created by xmigra
      return <<-"END_OF_SQL"
PRINT N'Removing data access artifacts:';
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @obj_name NVARCHAR(256); -- Name of object to drop
DECLARE @obj_type NVARCHAR(40); -- Type of object to drop

DECLARE AccObjs_cursor CURSOR LOCAL FOR
SELECT [name], [type]
FROM [xmigra].[access_objects]
ORDER BY [order] DESC;

OPEN AccObjs_cursor;

FETCH NEXT FROM AccObjs_cursor INTO @obj_name, @obj_type;

WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sqlcmd = N'DROP ' + @obj_type + N' ' + @obj_name + N';';
  EXEC sp_executesql @sqlcmd;
  
  FETCH NEXT FROM AccObjs_cursor INTO @obj_name, @obj_type;
END;

CLOSE AccObjs_cursor;
DEALLOCATE AccObjs_cursor;

DELETE FROM [xmigra].[access_objects];

END_OF_SQL
    end
    
    def remove_undesired_indexes_sql
      <<-"END_OF_SQL"
PRINT N'Removing undesired indexes:';
-- Iterate over indexes in [xmigra].[indexes] that don't have an entry in
-- [xmigra].[updated_indexes].
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @index_name NVARCHAR(256); -- Name of index to drop
DECLARE @table_name SYSNAME; -- Name of table owning index
DECLARE @match_count INT; -- Number of matching index names

DECLARE Index_cursor CURSOR LOCAL FOR
SELECT 
  xi.[name], 
  MAX(QUOTENAME(OBJECT_SCHEMA_NAME(si.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(si.object_id))), 
  COUNT(*)
FROM [xmigra].[indexes] xi
INNER JOIN sys.indexes si ON si.[name] = xi.[name]
WHERE xi.[IndexID] NOT IN (
  SELECT [IndexID]
  FROM [xmigra].[updated_indexes]
)
GROUP BY xi.[name];

OPEN Index_cursor;

FETCH NEXT FROM Index_cursor INTO @index_name, @table_name, @match_count;

WHILE @@FETCH_STATUS = 0 BEGIN
  IF @match_count > 1
  BEGIN
    RAISERROR(N'Multiple indexes are named %s', 11, 1, @index_name);
  END;
  
  SET @sqlcmd = N'DROP INDEX ' + @index_name + N' ON ' + @table_name + N';';
  EXEC sp_executesql @sqlcmd;
  PRINT N'    Removed ' + @index_name + N'.';
  
  FETCH NEXT FROM Index_cursor INTO @index_name, @table_name, @match_count;
END;

CLOSE Index_cursor;
DEALLOCATE Index_cursor;

DELETE FROM [xmigra].[indexes]
WHERE [IndexID] NOT IN (
  SELECT ui.[IndexID]
  FROM [xmigra].[updated_indexes] ui
);
      END_OF_SQL
    end
    
    def remove_undesired_statistics_sql
      <<-"END_OF_SQL"
PRINT N'Removing undesired statistics objects:';
-- Iterate over statistics in [xmigra].[statistics] that don't have an entry in
-- [xmigra].[updated_statistics].
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @statsobj_name NVARCHAR(256); -- Name of statistics object to drop
DECLARE @table_name SYSNAME; -- Name of table owning the statistics object
DECLARE @match_count INT; -- Number of matching statistics object names

DECLARE Stats_cursor CURSOR LOCAL FOR
SELECT 
  QUOTENAME(xs.[Name]), 
  MAX(QUOTENAME(OBJECT_SCHEMA_NAME(ss.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(ss.object_id))), 
  COUNT(ss.object_id)
FROM [xmigra].[statistics] xs
INNER JOIN sys.stats ss ON ss.[name] = xs.[Name]
WHERE xs.[Columns] NOT IN (
  SELECT us.[Columns]
  FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = xs.[Name]
)
GROUP BY xs.[Name];

OPEN Stats_cursor;

FETCH NEXT FROM Stats_cursor INTO @statsobj_name, @table_name, @match_count;

WHILE @@FETCH_STATUS = 0 BEGIN
  IF @match_count > 1
  BEGIN
    RAISERROR(N'Multiple indexes are named %s', 11, 1, @statsobj_name);
  END;
  
  SET @sqlcmd = N'DROP STATISTICS ' + @table_name + N'.' + @statsobj_name + N';';
  EXEC sp_executesql @sqlcmd;
  PRINT N'    Removed statistics object ' + @statsobj_name + N'.'
  
  FETCH NEXT FROM Stats_cursor INTO @statsobj_name, @table_name, @match_count;
END;

CLOSE Stats_cursor;
DEALLOCATE Stats_cursor;

DELETE FROM [xmigra].[statistics]
WHERE [Columns] NOT IN (
  SELECT us.[Columns]
  FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = [Name]
);
      END_OF_SQL
    end
    
    def create_new_indexes_sql
      indexes.collect do |index|
        index_id_literal = MSSQLSpecifics.string_literal(index.id)
        index_name_literal = MSSQLSpecifics.string_literal(index.name)
        <<-"END_OF_SQL"
PRINT N'Index ' + #{index_id_literal} + ':';
IF EXISTS(
  SELECT * FROM [xmigra].[updated_indexes] ui
  WHERE ui.[IndexID] = #{index_id_literal}
  AND ui.[IndexID] NOT IN (
    SELECT i.[IndexID] FROM [xmigra].[indexes] i
  )
)
BEGIN
  IF EXISTS (
    SELECT * FROM sys.indexes
    WHERE [name] = #{index_name_literal}
  )
  BEGIN
    RAISERROR(N'An index already exists named %s', 11, 1, #{index_name_literal});
  END;
  
  PRINT N'    Creating...';
  #{index.definition_sql};
  
  IF (SELECT COUNT(*) FROM sys.indexes WHERE [name] = #{index_name_literal}) <> 1
  BEGIN
    RAISERROR(N'Index %s was not created by its definition.', 11, 1,
      #{index_name_literal});
  END;

  INSERT INTO [xmigra].[indexes] ([IndexID], [name])
  VALUES (#{index_id_literal}, #{index_name_literal});
END
ELSE
BEGIN
  PRINT N'    Already exists.';
END;
        END_OF_SQL
      end.join(ddl_block_separator)
    end
    
    def create_new_statistics_sql
      stats_objs.collect do |stats_obj|
        stats_name = MSSQLSpecifics.string_literal(stats_obj.name)
        strlit = lambda {|s| MSSQLSpecifics.string_literal(s)}
        
        stats_obj.creation_sql
        <<-"END_OF_SQL"
PRINT N'Statistics object #{stats_obj.name}:';
IF EXISTS (
  SELECT * FROM [xmigra].[updated_statistics] us
  WHERE us.[Name] = #{stats_name}
  AND us.[Columns] NOT IN (
    SELECT s.[Columns]
    FROM [xmigra].[statistics] s
    WHERE s.[Name] = us.[Name]
  )
)
BEGIN
  IF EXISTS (
    SELECT * FROM sys.stats
    WHERE [name] = #{stats_name}
  )
  BEGIN
    RAISERROR(N'A statistics object named %s already exists.', 11, 1, #{stats_name})
  END;
  
  PRINT N'    Creating...';
  #{stats_obj.creation_sql}
  
  INSERT INTO [xmigra].[statistics] ([Name], [Columns])
  VALUES (#{stats_name}, #{strlit[stats_obj.columns]})
END
ELSE
BEGIN
  PRINT N'    Already exists.';
END;
        END_OF_SQL
      end.join(ddl_block_separator)
    end
    
    def upgrade_cleanup_sql
      <<-"END_OF_SQL"
PRINT N'Cleaning up from the upgrade:';
DROP TABLE [xmigra].[migrations];
DROP TABLE [xmigra].[updated_indexes];
DROP TABLE [xmigra].[updated_statistics];
      END_OF_SQL
    end
    
    def ensure_permissions_table_sql
      strlit = MSSQLSpecifics.method(:string_literal)
      <<-"END_OF_SQL"
-- ------------ SET UP XMIGRA PERMISSION TRACKING OBJECTS ------------ --

PRINT N'Setting up XMigra permission tracking:';
IF NOT EXISTS (
  SELECT * FROM sys.schemas
  WHERE name = N'xmigra'
)
BEGIN
  EXEC sp_executesql N'
    CREATE SCHEMA [xmigra] AUTHORIZATION [dbo];
  ';
END;
GO

IF NOT EXISTS(
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[revokable_permissions]')
  AND type IN (N'U')
)
BEGIN
  CREATE TABLE [xmigra].[revokable_permissions] (
    [permissions] nvarchar(200) NOT NULL,
    [object] nvarchar(260) NOT NULL,
    [principal_id] int NOT NULL
  ) ON [PRIMARY];
END;
GO

IF EXISTS(
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'[xmigra].[ip_prepare_revoke]')
  AND type IN (N'P', N'PC')
)
BEGIN
  DROP PROCEDURE [xmigra].[ip_prepare_revoke];
END;
GO

CREATE PROCEDURE [xmigra].[ip_prepare_revoke]
(
  @permissions nvarchar(200),
  @object nvarchar(260),
  @principal sysname
)
AS
BEGIN
  INSERT INTO [xmigra].[revokable_permissions] ([permissions], [object], [principal_id])
  VALUES (@permissions, @object, DATABASE_PRINCIPAL_ID(@principal));
END;
      END_OF_SQL
    end
    
    def revoke_previous_permissions_sql
      <<-"END_OF_SQL"

-- ------------- REVOKING PREVIOUSLY GRANTED PERMISSIONS ------------- --

PRINT N'Revoking previously granted permissions:';
-- Iterate over permissions listed in [xmigra].[revokable_permissions]
DECLARE @sqlcmd NVARCHAR(1000); -- Built SQL command
DECLARE @permissions NVARCHAR(200); 
DECLARE @object NVARCHAR(260); 
DECLARE @principal NVARCHAR(150);

DECLARE Permission_cursor CURSOR LOCAL FOR
SELECT
  xp.[permissions],
  xp.[object],
  QUOTENAME(sdp.name)
FROM [xmigra].[revokable_permissions] xp
INNER JOIN sys.database_principals sdp ON xp.principal_id = sdp.principal_id;

OPEN Permission_cursor;

FETCH NEXT FROM Permission_cursor INTO @permissions, @object, @principal;

WHILE @@FETCH_STATUS = 0 BEGIN
  SET @sqlcmd = N'REVOKE ' + @permissions + N' ON ' + @object + ' FROM ' + @principal + N';';
  BEGIN TRY
    EXEC sp_executesql @sqlcmd;
  END TRY
  BEGIN CATCH
  END CATCH
  
  FETCH NEXT FROM Permission_cursor INTO @permissions, @object, @principal;
END;

CLOSE Permission_cursor;
DEALLOCATE Permission_cursor;

DELETE FROM [xmigra].[revokable_permissions];
      END_OF_SQL
    end
    
    def granting_permissions_comment_sql
      <<-"END_OF_SQL"
      
-- ---------------------- GRANTING PERMISSIONS ----------------------- --

      END_OF_SQL
    end
    
    def grant_permissions_sql(permissions, object, principal)
      strlit = MSSQLSpecifics.method(:string_literal)
      permissions_string = permissions.to_a.join(', ')
      
      <<-"END_OF_SQL"
PRINT N'Granting #{permissions_string} on #{object} to #{principal}:';
GRANT #{permissions_string} ON #{object} TO #{principal};
    EXEC [xmigra].[ip_prepare_revoke] #{strlit[permissions_string]}, #{strlit[object]}, #{strlit[principal]};
      END_OF_SQL
    end
    
    def insert_access_creation_record_sql
      name_literal = MSSQLSpecifics.string_literal(quoted_name)
      
      <<-"END_OF_SQL"
INSERT INTO [xmigra].[access_objects] ([type], [name])
VALUES (N'#{self.class::OBJECT_TYPE}', #{name_literal});
      END_OF_SQL
    end
    
    # Call on an extended Migration object to get the SQL to execute.
    def migration_application_sql
      id_literal = MSSQLSpecifics.string_literal(id)
      template = <<-"END_OF_SQL"
IF EXISTS (
  SELECT * FROM [xmigra].[migrations]
  WHERE [MigrationID] = #{id_literal}
  AND [Install] <> 0
)
BEGIN
  PRINT #{MSSQLSpecifics.string_literal('Applying "' + File.basename(file_path) + '":')};
  
%s

  INSERT INTO [xmigra].[applied] ([MigrationID], [Description])
  VALUES (#{id_literal}, #{MSSQLSpecifics.string_literal(description)});
END;
      END_OF_SQL
      
      parts = []
      
      each_batch(sql) do |batch|
        parts << batch
      end
      
      return (template % parts.collect do |batch|
        "EXEC sp_executesql @statement = " + MSSQLSpecifics.string_literal(batch) + ";"
      end.join("\n"))
    end
    
    def reversion_tracking_sql
      "DELETE FROM [xmigra].[applied] WHERE [MigrationID] = '#{id}';\n"
    end
    
    def each_batch(sql)
      current_batch_lines = []
      sql.each_line do |line|
        if line.strip.upcase == 'GO'
          batch = current_batch_lines.join('')
          yield batch unless batch.strip.empty?
          current_batch_lines.clear
        else
          current_batch_lines << line
        end
      end
      unless current_batch_lines.empty?
        batch = current_batch_lines.join('')
        yield batch unless batch.strip.empty?
      end
    end
    
    def batch_separator
      "GO\n"
    end
    
    def check_existence_sql(for_existence, error_message)
      error_message = sprintf(error_message, quoted_name)
      
      return <<-"END_OF_SQL"
    
IF #{"NOT" if for_existence} #{existence_test_sql}
RAISERROR(N'#{error_message}', 11, 1);
      END_OF_SQL
    end
    
    def creation_notice
      return "PRINT " + MSSQLSpecifics.string_literal("Creating #{printable_type} #{quoted_name}:") + ";"
    end
    
    def name_parts
      if m = DBNAME_PATTERN.match(name)
        [m[1], m[2]].compact.collect do |p|
          MSSQLSpecifics.strip_identifier_quoting(p)
        end
      else
        raise XMigra::Error, "Invalid database object name"
      end
    end
    
    def quoted_name
      name_parts.collect do |p|
        "[]".insert(1, p)
      end.join('.')
    end
    
    def object_type_codes
      MSSQLSpecifics.object_type_codes(self)
    end
    
    def existence_test_sql
      object_type_list = object_type_codes.collect {|t| "N'#{t}'"}.join(', ')
      
      return <<-"END_OF_SQL"
EXISTS (
  SELECT * FROM sys.objects
  WHERE object_id = OBJECT_ID(N'#{quoted_name}')
  AND type IN (#{object_type_list})
)
      END_OF_SQL
    end
    
    def branch_id_literal
      @mssql_branch_id_literal ||= MSSQLSpecifics.string_literal(XMigra.secure_digest(branch_identifier))
    end
    
    def upgrading_to_new_branch_test_sql
      return "(0 = 1)" unless respond_to? :branch_identifier
      
      (<<-"END_OF_SQL").chomp
(EXISTS (
  SELECT TOP(1) * FROM [xmigra].[branch_upgrade]
  WHERE [Next] = #{branch_id_literal}
))
      END_OF_SQL
    end
    
    def branch_upgrade_sql
      return unless respond_to? :branch_identifier
      
      parts = [<<-"END_OF_SQL"]
IF #{upgrading_to_new_branch_test_sql}
BEGIN
  PRINT N'Migrating from previous schema branch:';
  
  DECLARE @sqlcmd NVARCHAR(MAX);
  
  DECLARE CmdCursor CURSOR LOCAL FOR
  SELECT bu.[UpgradeSql]
  FROM [xmigra].[branch_upgrade] bu
  WHERE bu.[Next] = #{branch_id_literal}
  ORDER BY bu.[ApplicationOrder] ASC;
  
  OPEN CmdCursor;
  
  FETCH NEXT FROM CmdCursor INTO @sqlcmd;
  
  WHILE @@FETCH_STATUS = 0 BEGIN
    EXECUTE sp_executesql @sqlcmd;
    
    FETCH NEXT FROM CmdCursor INTO @sqlcmd;
  END;
  
  CLOSE CmdCursor;
  DEALLOCATE CmdCursor;
  
  DECLARE @applied NVARCHAR(80);
  DECLARE @old_branch NVARCHAR(80);
  
  SELECT TOP(1) @applied = [CompletesMigration], @old_branch = [Current]
  FROM [xmigra].[branch_upgrade]
  WHERE [Next] = #{branch_id_literal};
  
  -- Delete the "applied" record for the migration if there was one, so that
  -- a new record with this ID can be inserted.
  DELETE FROM [xmigra].[applied] WHERE [MigrationID] = @applied;
  
  -- Create a "version bridge" record in the "applied" table for the branch upgrade
  INSERT INTO [xmigra].[applied] ([MigrationID], [VersionBridgeMark], [Description])
  VALUES (@applied, 1, N'Branch upgrade from branch ' + @old_branch);
END;

DELETE FROM [xmigra].[branch_upgrade];

      END_OF_SQL
      
      if branch_upgrade.applicable? migrations
        batch_template = <<-"END_OF_SQL"
INSERT INTO [xmigra].[branch_upgrade]
([Current], [Next], [CompletesMigration], [UpgradeSql])
VALUES (
  #{branch_id_literal},
  #{MSSQLSpecifics.string_literal(branch_upgrade.target_branch)},
  #{MSSQLSpecifics.string_literal(branch_upgrade.migration_completed_id)},
  %s
);
        END_OF_SQL
        
        each_batch(branch_upgrade.sql) do |batch|
          # Insert the batch into the [xmigra].[branch_upgrade] table
          parts << (batch_template % MSSQLSpecifics.string_literal(batch))
        end
      else
        # Insert a placeholder that only declares the current branch of the schema
        parts << <<-"END_OF_SQL"
INSERT INTO [xmigra].[branch_upgrade] ([Current]) VALUES (#{branch_id_literal});
        END_OF_SQL
      end
      
      return parts.join("\n")
    end
    
    class << self
      def strip_identifier_quoting(s)
        case
        when s.empty? then return s
        when s[0,1] == "[" && s[-1,1] == "]" then return s[1..-2]
        when s[0,1] == '"' && s[-1,1] == '"' then return s[1..-2]
        else return s
        end
      end
    
      def object_type_codes(type)
        case type
        when StoredProcedure then %w{P PC}
        when View then ['V']
        when Function then %w{AF FN FS FT IF TF}
        end
      end
      
      def string_literal(s)
        "N'#{s.gsub("'","''")}'"
      end
      
      def init_schema(schema_config)
        loop do
          print "Use more verbose syntax compatible with SQL Server 2005 (y/N): "
          case $stdin.gets.strip
          when /^y(es)?$/i
            schema_config.dbinfo["MSSQL 2005 compatible"] = true
            puts "Configured for SQL Server 2005 compatibility mode."
            break
          when /^(n(o)?)?$/i
            break
          end
        end
      end
    end
  end
end
