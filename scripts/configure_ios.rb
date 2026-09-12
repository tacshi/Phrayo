require 'xcodeproj'
project = Xcodeproj::Project.open('ios/Runner.xcodeproj')
runner = project.targets.find { |t| t.name == 'Runner' }
group = project.main_group.find_subpath('Runner', false)
Dir['ios/Runner/*.swift'].each do |path|
  name=File.basename(path)
  file=group.files.find { |f| f.path == name } || group.new_file(name)
  runner.source_build_phase.add_file_reference(file, true)
end
project.build_configurations.each { |c| c.build_settings['IPHONEOS_DEPLOYMENT_TARGET']='26.0' }
runner.build_configurations.each do |c|
 c.build_settings['IPHONEOS_DEPLOYMENT_TARGET']='26.0'
 c.build_settings['PRODUCT_BUNDLE_IDENTIFIER']='app.capyvibe.phrayo'
 c.build_settings['SWIFT_VERSION']='5.0'
 c.build_settings['TARGETED_DEVICE_FAMILY']='1,2'
 c.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME']='AppIcon'
end
extension=project.targets.find { |t| t.name=='PhrayoActivity' } || project.new_target(:app_extension,'PhrayoActivity',:ios,'26.0')
extension_group=project.main_group.find_subpath('PhrayoActivity',true)
extension_group.set_source_tree('<group>')
extension_group.set_path('PhrayoActivity')
['PhrayoActivity.swift'].each do |name|
 file=extension_group.files.find { |f| f.path==name } || extension_group.new_file(name)
 extension.source_build_phase.add_file_reference(file,true)
end
['RecordingAttributes.swift','ActivityStopIntent.swift'].each do |name|
 file=group.files.find { |f| f.path==name }
 extension.source_build_phase.add_file_reference(file,true)
end
extension.build_configurations.each do |c|
 c.build_settings['PRODUCT_NAME']='$(TARGET_NAME)'
 c.build_settings['INFOPLIST_FILE']='PhrayoActivity/Info.plist'
 c.build_settings['PRODUCT_BUNDLE_IDENTIFIER']='app.capyvibe.phrayo.liveactivity'
 c.build_settings['SWIFT_VERSION']='5.0'
 c.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) ACTIVITY_EXTENSION'
 c.build_settings['APPLICATION_EXTENSION_API_ONLY']='YES'
 c.build_settings['SKIP_INSTALL']='YES'
 c.build_settings['TARGETED_DEVICE_FAMILY']='1,2'
 c.build_settings['LD_RUNPATH_SEARCH_PATHS']='$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
 c.build_settings['DEVELOPMENT_TEAM']=runner.build_configurations.first.build_settings['DEVELOPMENT_TEAM']
end
runner.add_dependency(extension) unless runner.dependencies.any? { |d| d.target==extension }
phase=runner.copy_files_build_phases.find { |p| p.name=='Embed App Extensions' } || runner.new_copy_files_build_phase('Embed App Extensions')
phase.dst_subfolder_spec='13'
phase.add_file_reference(extension.product_reference,true)
# Embed before Flutter's final binary thinning stage.
runner.build_phases.delete(phase)
runner.build_phases.insert(2,phase)
['en','zh-Hans','zh-Hant'].each do |locale|
 project.root_object.known_regions << locale unless project.root_object.known_regions.include?(locale)
end
['InfoPlist.strings','Localizable.strings'].each do |name|
 variants=group.children.find { |f| f.isa=='PBXVariantGroup' && f.name==name } || group.new_variant_group(name)
 ['en','zh-Hans','zh-Hant'].each do |locale|
  file=variants.files.find { |f| f.name==locale } || variants.new_file("#{locale}.lproj/#{name}")
  file.name=locale
 end
 runner.resources_build_phase.add_file_reference(variants,true)
 extension.resources_build_phase.add_file_reference(variants,true) if name=='Localizable.strings'
end
privacy=group.files.find { |f| f.path=='PrivacyInfo.xcprivacy' } || group.new_file('PrivacyInfo.xcprivacy')
runner.resources_build_phase.add_file_reference(privacy,true)
project.save
