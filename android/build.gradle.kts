allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}


subprojects {
    // 强制所有 Android 插件模块使用 compileSdk 36。
    // 必须在 afterEvaluate 中设置：plugins.withId 回调早于插件自身
    // android{} 块执行，会被插件内 compileSdk=34 覆盖，导致
    // :file_picker 等插件 AAR 元数据检查失败（需要 ≥36）。
    afterEvaluate {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 36
    }
}
