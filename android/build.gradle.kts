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


// 强制所有 Android 插件模块使用 compileSdk 36。
// 用 gradle.projectsEvaluated：所有项目求值完成后统一覆盖，
// 避免 plugins.withId 早于插件自身 android{} 块、以及
// afterEvaluate 在已求值项目上注册报错的问题。
gradle.projectsEvaluated {
    subprojects {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.compileSdk = 36
    }
}
