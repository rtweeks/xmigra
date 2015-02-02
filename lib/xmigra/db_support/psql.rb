require 'digest/md5'
require 'xmigra/utils'

module XMigra
  module PgSQLSpecifics
    DatabaseSupportModules << self
    
    SYSTEM_NAME = 'PostgreSQL'
    
    IDENTIFIER_SUBPATTERN = '[[:alpha:]_][[:alnum:]_$]*|"(?:[^"]|"")+"'
    DBNAME_PATTERN = /^
      (?:(#{IDENTIFIER_SUBPATTERN})\.)?
      (#{IDENTIFIER_SUBPATTERN})
      (\(
        (?:
          (?:#{IDENTIFIER_SUBPATTERN}\.)?#{IDENTIFIER_SUBPATTERN}
          (?:,\s*
            (?:#{IDENTIFIER_SUBPATTERN}\.)?#{IDENTIFIER_SUBPATTERN}
          )*
        )?
      \))?
    $/ix
    
    def filename_metavariable; "[{filename}]"; end
    
    def in_ddl_transaction
      ["BEGIN;", yield, "COMMIT;"].join("\n")
    end
    
    def check_execution_environment_sql
      XMigra.dedent %Q{
        CREATE OR REPLACE FUNCTION enable_plpgsql() RETURNS VOID AS $$
          CREATE LANGUAGE plpgsql;
        $$ LANGUAGE SQL;

        SELECT
          CASE
          WHEN EXISTS(
            SELECT 1
            FROM pg_catalog.pg_language
            WHERE lanname = 'plpgsql'
          )
          THEN NULL
          ELSE enable_plpgsql()
          END;

        DROP FUNCTION enable_plpgsql();

        CREATE OR REPLACE FUNCTION f_raise(text)
        RETURNS VOID
        LANGUAGE plpgsql AS
        $$
        BEGIN
          RAISE EXCEPTION '%', $1;
        END;
        $$;
        
        CREATE OR REPLACE FUNCTION f_alert(text)
        RETURNS VOID
        LANGUAGE plpgsql AS
        $$
        BEGIN
          RAISE NOTICE '%', $1;
        END;
        $$;
        
        CREATE OR REPLACE FUNCTION f_resolvename(varchar(100), varchar(100)) 
        RETURNS OID 
        LANGUAGE plpgsql AS
        $$
        DECLARE
          Statement TEXT;
          Result OID;
        BEGIN
          Statement := 'SELECT ' || quote_literal($1) || '::' || $2 || '::oid;';
          EXECUTE Statement INTO Result;
          RETURN Result;
        EXCEPTION
          WHEN OTHERS THEN RETURN NULL;
        END;
        $$;

        SELECT
          CASE
          WHEN current_database() IN ('postgres', 'template0', 'template1')
            THEN f_raise('Invalid target database.')
          END;
      }
    end
    
    def ensure_version_tables_sql
      PgSQLSpecifics.in_plpgsql %Q{
        RAISE NOTICE 'Ensuring version tables:';
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.schemata
          WHERE schema_name = 'xmigra'
        ) THEN
          CREATE SCHEMA xmigra;
        END IF;
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' AND table_name = 'applied'
        ) THEN
          CREATE TABLE xmigra.applied (
            "MigrationID"          varchar(80) PRIMARY KEY,
            "ApplicationOrder"     SERIAL,
            "VersionBridgeMark"    boolean DEFAULT FALSE NOT NULL,
            "Description"          text NOT NULL
          );
        END IF;
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' AND table_name = 'access_objects'
        ) THEN
          CREATE TABLE xmigra.access_objects (
            "type" varchar(40) NOT NULL,
            "name" varchar(150) PRIMARY KEY,
            "order" SERIAL
          );
        END IF;
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' and table_name = 'indexes'
        ) THEN
          CREATE TABLE xmigra.indexes (
            "IndexID" varchar(80) PRIMARY KEY,
            "name" varchar(150) NOT NULL
          );
        END IF;
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' and table_name = 'branch_upgrade'
        ) THEN
          CREATE TABLE xmigra.branch_upgrade (
            "ApplicationOrder" SERIAL,
            "Current" varchar(80) PRIMARY KEY,
            "Next" varchar(80) NULL,
            "UpgradeSql" text NULL,
            "CompletesMigration" varchar(80) NULL
          );
        END IF;
        
        RAISE NOTICE '    done';
      }
    end
    
    def create_and_fill_migration_table_sql
      intro = XMigra.dedent %Q{
        CREATE TEMP TABLE temp$xmigra_migrations (
          "MigrationID"              varchar(80) NOT NULL,
          "ApplicationOrder"         int NOT NULL,
          "Description"              text NOT NULL,
          "Install"                  boolean DEFAULT FALSE NOT NULL
        ) ON COMMIT DROP;
      }
      
      mig_insert = XMigra.dedent %Q{
        INSERT INTO temp$xmigra_migrations ("MigrationID", "ApplicationOrder", "Description")
        VALUES (%s);
      }
      
      parts = [intro]
      migrations.each_with_index do |m, i|
        description_literal = PgSQLSpecifics.string_literal(m.description.strip)
        parts << (mig_insert % ["'#{m.id}', #{i + 1}, #{description_literal}"])
      end
      return parts.join('')
    end
    
    def create_and_fill_indexes_table_sql
      intro = XMigra.dedent %Q{
        CREATE TEMP TABLE temp$xmigra_updated_indexes (
          "IndexID"    varchar(80) PRIMARY KEY
        ) ON COMMIT DROP;
      }
      
      insertion = XMigra.dedent %Q{
        INSERT INTO temp$xmigra_updated_indexes ("IndexID") VALUES (%s);
      }
      
      return intro + indexes.collect do |index|
        insertion % [PgSQLSpecifics.string_literal(index.id)]
      end.join("\n")
    end
    
    def check_preceding_migrations_sql
      branch_check = production ? XMigra.dedent(%Q{
        IF EXISTS(
          SELECT * FROM xmigra.branch_upgrade LIMIT 1
        ) AND NOT EXISTS(
          SELECT * FROM xmigra.branch_upgrade LIMIT 1
          WHERE #{branch_id_literal} IN ("Current", "Next")
        ) THEN
          RAISE EXCEPTION 'Existing database is from a different (and non-upgradable) branch.';
        END IF;
        
      }, '  ') : ''
      
      PgSQLSpecifics.in_plpgsql({:VersionBridge => "INT"}, %Q{
        #{branch_check[2..-1]}
        
        RAISE NOTICE 'Checking preceding migrations:';
        
        IF NOT #{upgrading_to_new_branch_test_sql} THEN
          VersionBridge := (
            SELECT COALESCE(MAX("ApplicationOrder"), 0)
            FROM xmigra.applied
            WHERE "VersionBridgeMark"
          );
          
          IF EXISTS (
            SELECT * FROM xmigra.applied a
            WHERE a."ApplicationOrder" > VersionBridge
            AND a."MigrationID" NOT IN (
              SELECT m."MigrationID" FROM temp$xmigra_migrations m
            )
          ) THEN
            RAISE EXCEPTION 'Unknown in-branch migrations have been applied.';
          END IF;
        END IF;
        
        RAISE NOTICE '    done';
      })
    end
    
    def check_chain_continuity_sql
      PgSQLSpecifics.in_plpgsql({:VersionBridge => "INT"}, %Q{
        IF NOT #{upgrading_to_new_branch_test_sql} THEN
          RAISE NOTICE 'Checking migration chain continuity:';
          
          VersionBridge := (
            SELECT COALESCE(MAX(m."ApplicationOrder"), 0)
            FROM xmigra.applied a
            INNER JOIN temp$xmigra_migrations m
              ON a."MigrationID" = m."MigrationID"
            WHERE a."VersionBridgeMark"
          );
          
          IF EXISTS(
            SELECT *
            FROM xmigra.applied a
            INNER JOIN temp$xmigra_migrations m
              ON a."MigrationID" = m."MigrationID"
            INNER JOIN temp$xmigra_migrations p
              ON m."ApplicationOrder" - 1 = p."ApplicationOrder"
            WHERE p."ApplicationOrder" > VersionBridge
            AND p."MigrationID" NOT IN (
              SELECT a2."MigrationID" FROM xmigra.applied a2
            )
          ) THEN
            RAISE EXCEPTION 'Previously applied migrations interrupt the continuity of the migration chain.';
          END IF;
          
          RAISE NOTICE '    done';
        END IF;
      })
    end
    
    def select_for_install_sql
      PgSQLSpecifics.in_plpgsql({:VersionBridge => "INT"}, %Q{
        RAISE NOTICE 'Selecting migrations to apply:';
        
        IF #{upgrading_to_new_branch_test_sql} THEN
          VersionBridge := (
            SELECT MAX(m."ApplicationOrder")
            FROM temp$xmigra_migrations m
            INNER JOIN xmigra.branch_upgrade bu
              ON m."MigrationID" = bu."CompletesMigration"
          );
          
          UPDATE temp$xmigra_migrations
          SET "Install" = TRUE
          WHERE "ApplicationOrder" > VersionBridge;
        ELSE
          VersionBridge := (
            SELECT COALESCE(MAX(m."ApplicationOrder"), 0)
            FROM xmigra.applied a
            INNER JOIN temp$xmigra_migrations m
              ON a."MigrationID" = m."MigrationID"
              WHERE a."VersionBridgeMark"
          );
          
          UPDATE temp$xmigra_migrations
          SET "Install" = TRUE
          WHERE "MigrationID" NOT IN (
            SELECT a."MigrationID" FROM xmigra.applied a
          );
        END IF;
        
        RAISE NOTICE '    done';
      })
    end
    
    def production_config_check_sql
      return if production
      
      PgSQLSpecifics.in_plpgsql %Q{
        RAISE NOTICE 'Checking for production status:';
        
        IF EXISTS(
          SELECT * FROM temp$xmigra_migrations
          WHERE "MigrationID" = '#{@migrations[0].id}'
          AND "Install"
        ) THEN
          CREATE TABLE xmigra.development (
            info varchar(200) PRIMARY KEY
          );
        END IF;
        
        IF NOT EXISTS(
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' AND table_name = 'development'
        ) THEN
          RAISE EXCEPTION 'Development script cannot be applied to a production database.';
        END IF;
        
        RAISE NOTICE '    done';
      }
    end
    
    def remove_access_artifacts_sql
      PgSQLSpecifics.in_plpgsql({:AccessObject => 'RECORD'}, %Q{
        RAISE NOTICE 'Removing data access artifacts:';
        
        FOR AccessObject IN 
        SELECT "name", "type" 
        FROM xmigra.access_objects 
        ORDER BY "order" DESC 
        LOOP
          EXECUTE 'DROP ' || AccessObject."type" || ' ' || AccessObject."name" || ';';
        END LOOP;
        
        DELETE FROM xmigra.access_objects;
        
        RAISE NOTICE '    done';
      })
    end
    
    def remove_undesired_indexes_sql
      PgSQLSpecifics.in_plpgsql({:IndexName => 'varchar(150)'}, %Q{
        RAISE NOTICE 'Removing undesired indexes:';
        
        FOR IndexName IN
        SELECT xi."name"
        FROM xmigra.indexes xi
        WHERE xi."IndexID" NOT IN (
          SELECT "IndexID"
          FROM temp$xmigra_updated_indexes
        )
        LOOP
          EXECUTE 'DROP INDEX ' || IndexName || ';';
        END LOOP;
        
        DELETE FROM xmigra.indexes
        WHERE "IndexID" NOT IN (
          SELECT ui."IndexID"
          FROM temp$xmigra_updated_indexes ui
        );
        
        RAISE NOTICE '    done';
      })
    end
    
    def create_new_indexes_sql
      return nil if indexes.empty?
      PgSQLSpecifics.in_plpgsql(indexes.collect do |index|
        XMigra.dedent %Q{
          RAISE NOTICE 'Index #{index.id}:';
          
          IF EXISTS(
            SELECT * FROM temp$xmigra_updated_indexes ui
            WHERE ui."IndexID" = '#{index.id}'
            AND ui."IndexID" NOT IN (
              SELECT i."IndexID" FROM xmigra.indexes i
            )
          ) THEN
            RAISE NOTICE '    creating...';
            
            EXECUTE #{PgSQLSpecifics.string_literal index.definition_sql};
            
            INSERT INTO xmigra.indexes ("IndexID", "name")
            VALUES ('#{index.id}', #{PgSQLSpecifics.string_literal index.quoted_name});
            
            RAISE NOTICE '    done';
          ELSE
            RAISE NOTICE '    already exists';
          END IF;
        }
        
      end.join("\n"))
    end
    
    def ensure_permissions_table_sql
      "-- ------------ SET UP XMIGRA PERMISSION TRACKING OBJECTS ------------ --\n\n" +
      PgSQLSpecifics.in_plpgsql(%Q{
        RAISE NOTICE 'Setting up XMigra permission tracking:';
        
        IF NOT EXISTS (
          SELECT * FROM information_schema.schemata
          WHERE schema_name = 'xmigra'
        ) THEN
          CREATE SCHEMA xmigra;
        END IF;
        
        IF NOT EXISTS (
          SELECT * FROM information_schema.tables
          WHERE table_schema = 'xmigra' AND table_name = 'revokable_permissions'
        ) THEN
          CREATE TABLE xmigra.revokable_permissions (
            permissions varchar(200) NOT NULL,
            "object" varchar(150) NOT NULL,
            "role" oid NOT NULL
          );
        END IF;
        
      }) + XMigra.dedent(%Q{
        CREATE OR REPLACE FUNCTION xmigra.ip_prepare_revoke(varchar(200), varchar(150), varchar(80)) RETURNS VOID AS $$
        BEGIN
          INSERT INTO xmigra.revokable_permissions (permissions, "object", "role")
          SELECT $1, $2, r.oid
          FROM pg_catalog.pg_roles r
          WHERE r.rolname = $3;
        END;
        $$ LANGUAGE plpgsql;
      })
    end
    
    def revoke_previous_permissions_sql
      "-- ------------- REVOKING PREVIOUSLY GRANTED PERMISSIONS ------------- --\n\n" +
      PgSQLSpecifics.in_plpgsql({:PermissionGrant => 'RECORD'}, %Q{
        RAISE NOTICE 'Revoking previously granted permissions:';
        
        FOR PermissionGrant IN
        SELECT p.permissions, p."object", r.rolname AS "role"
        FROM xmigra.revokable_permissions p
        INNER JOIN pg_catalog.pg_roles r
          ON p."role" = r.oid
        LOOP
          EXECUTE 'REVOKE ' || PermissionGrant.permissions || ' ON ' || PermissionGrant."object" || ' FROM ' || PermissionGrant."role";
        END LOOP;
        
        RAISE NOTICE '    done';
      })
    end
    
    def granting_permissions_comment_sql
      "\n-- ---------------------- GRANTING PERMISSIONS ----------------------- --\n\n"
    end
    
    def grant_permissions_sql(permissions, object, principal)
      strlit = PgSQLSpecifics.method(:string_literal)
      permissions_string = permissions.to_a.join(', ')
      
      PgSQLSpecifics.in_plpgsql %Q{
        RAISE NOTICE 'Granting #{permissions_string} on #{object} to #{principal}:';
        GRANT #{permissions_string} ON #{object} TO #{principal};
            PERFORM xmigra.ip_prepare_revoke(#{strlit[permissions_string]}, #{strlit[object]}, #{strlit[principal]});
        RAISE NOTICE '    done';
      }
    end
    
    def insert_access_creation_record_sql
      XMigra.dedent %Q{
        INSERT INTO xmigra.access_objects ("type", "name")
        VALUES ('#{self.class::OBJECT_TYPE}', #{PgSQLSpecifics.string_literal quoted_name});
      }
    end
    
    def migration_application_sql
      PgSQLSpecifics.in_plpgsql %Q{
        IF EXISTS (
          SELECT * FROM temp$xmigra_migrations
          WHERE "MigrationID" = '#{id}'
          AND "Install"
        ) THEN
          RAISE NOTICE #{PgSQLSpecifics.string_literal %Q{Applying "#{File.basename(file_path)}":}};
          
          EXECUTE #{PgSQLSpecifics.string_literal sql};
          
          INSERT INTO xmigra.applied ("MigrationID", "Description")
          VALUES ('#{id}', #{PgSQLSpecifics.string_literal description});
          
          RAISE NOTICE '    done';
        END IF;
      }
    end
    
    def check_existence_sql(for_existence, error_message)
      error_message_literal = PgSQLSpecifics.string_literal sprintf(error_message, quoted_name)
      
      XMigra.dedent %Q{
        SELECT CASE
          WHEN #{existence_test_sql(!for_existence)}
          THEN f_raise(#{error_message_literal})
          END;
      }
    end
    
    def creation_notice
      "SELECT f_alert(#{PgSQLSpecifics.string_literal "Creating #{printable_type} #{quoted_name}:"});"
    end
    
    def name_parts
      if m = DBNAME_PATTERN.match(name)
        [m[1], m[2]].compact.collect do |p|
          PgSQLSpecifics.strip_identifier_quoting(p)
        end.tap do |result|
          result << [].tap {|types| m[3][1..-2].scan(DBNAME_PATTERN) {|m| types << $&}} if m[3]
        end
      else
        raise XMigra::Error, "Invalid database object name"
      end
    end
    
    def quoted_name
      formatted_name {|p| '""'.insert(1, p.gsub('"', '""'))}
    end
    
    def unquoted_name
      formatted_name {|p| p}
    end
    
    def formatted_name
      ''.tap do |result|
        name_parts.each do |p|
          if p.kind_of? Array
            result << '()'.insert(1, p.join(', '))
          else
            result << '.' unless result.empty?
            result << (yield p)
          end
        end
      end
    end
    
    def existence_test_sql(for_existence=true)
      name_literal = PgSQLSpecifics.string_literal(quoted_name)
      oid_type_strlit = PgSQLSpecifics.string_literal(PgSQLSpecifics.oid_type(self))
      "f_resolvename(#{name_literal}, #{oid_type_strlit}) IS #{"NOT " if for_existence}NULL"
    end
    
    def branch_id_literal
      @pgsql_branch_id_literal ||= PgSQLSpecifics.string_literal(
        XMigra.secure_digest(branch_identifier)
      )
    end
    
    def upgrading_to_new_branch_test_sql
      return "FALSE" unless respond_to? :branch_identifier
      
      XMigra.dedent %Q{
        (EXISTS (
          SELECT * FROM xmigra.branch_upgrade
          WHERE "Next" = #{branch_id_literal}
          LIMIT 1
        ))
      }
    end
    
    def branch_upgrade_sql
      return unless respond_to? :branch_identifier
      
      parts = []
      
      parts << PgSQLSpecifics.in_plpgsql({
        :UpgradeCommands => 'text', 
        :CompletedMigration => 'RECORD'
      }, %Q{
        IF #{upgrading_to_new_branch_test_sql} THEN
          RAISE NOTICE 'Migrating from previous schema branch:';
          
          FOR UpgradeCommands IN
          SELECT bu."UpgradeSql"
          FROM xmigra.branch_upgrade bu
          WHERE bu."Next" = #{branch_id_literal}
          ORDER BY bu."ApplicationOrder" ASC
          LOOP
            EXECUTE UpgradeCommads;
          END LOOP;
        
          SELECT "CompletesMigration" AS applied, "Current" AS old_branch
          INTO CompletedMigration
          FROM xmigra.branch_upgrade
          WHERE "Next" = #{branch_id_literal};
          
          DELETE FROM xmigra.applied WHERE "MigrationID" = CompletedMigration.applied;
          
          INSERT INTO xmigra.applied ("MigrationID", "VersionBridgeMark", "Description")
          VALUES (CompletedMigration.applied, TRUE, 'Branch upgrade from branch ' || CompletedMigration.old_branch || '.');
          
          RAISE NOTICE '    done';
        END IF;
        
        DELETE FROM xmigra.branch_upgrade;
        
      })
      
      if branch_upgrade.applicable? migrations
        parts << XMigra.dedent(%Q{
          INSERT INTO xmigra.branch_upgrade
          ("Current", "Next", "CompletesMigration", "UpgradeSql")
          VALUES (
            #{branch_id_literal},
            #{PgSQLSpecifics.string_literal branch_upgrade.target_branch},
            #{PgSQLSpecifics.string_literal branch_upgrade.migration_completed_id},
            #{PgSQLSpecifics.string_literal branch_upgrade.sql}
          );
        })
      else
        parts << %Q{INSERT INTO xmigra.branch_upgrade ("Current") VALUES (#{branch_id_literal});\n}
      end
      
      return parts.join("\n")
    end
    
    class <<self
      def in_plpgsql(*args)
        variables = args[0].kind_of?(Hash) ? args.shift : {}
        s = args.shift
        name = "xmigra_" + Digest::MD5.hexdigest(s)
        
        decl_block = (if variables.length > 0
          ["DECLARE\n"].tap do |lines|
            variables.each_pair do |n, d|
              lines << "  #{n} #{d};\n"
            end
          end.join('')
        else
          ''
        end)
        
        s = s[0..-2] if s.end_with? "\n"
        XMigra.dedent(%Q{
          CREATE OR REPLACE FUNCTION #{name}() RETURNS VOID AS $$
          #{decl_block}BEGIN
          %s
          END;
          $$ LANGUAGE plpgsql;
          
          SELECT #{name}();
          DROP FUNCTION #{name}();
        }) % [XMigra.dedent(s)]
      end
      
      def string_literal(s)
        "'%s'" % [s.gsub("'", "''")]
      end
      
      def strip_identifier_quoting(s)
        case
        when s[0,1] == '"' && s[-1,1] == '"' then return s[1..-2].gsub('""', '"')
        else return s
        end
      end
      
      def oid_type(type)
        case type
        when View then 'regclass'
        when Function then 'regprocedure'
        when Class
          raise XMigra::Error, "Invalid access object type '#{type.name}'"
        else
          raise XMigra::Error, "Invalid access object type '#{type.class.name}'"
        end
      end
    end
  end
end
