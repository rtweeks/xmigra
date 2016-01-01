
XMigra::DatabaseSupportModules.each do |db_module|
  ["migration", "index", "view", "function", "procedure"].each do |file_type_flag|
    run_test "#{db_module::SYSTEM_NAME} support for new #{file_type_flag} file" do
      in_xmigra_schema(:db_info=>{'system'=>db_module::SYSTEM_NAME}) do
        begin
          XMigra::Program.run(["new", "--no-edit", "--#{file_type_flag}", "foobarbaz"])
        rescue XMigra::NewAccessArtifactAdder::UnsupportedArtifactType
          # This is an acceptable error
        end
      end
    end
  end
end
