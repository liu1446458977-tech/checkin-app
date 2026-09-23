allprojects {
    repositories {
        // Flutter 引擎的 Maven 构件（Gradle 插件默认从
        // storage.googleapis.com/download.flutter.io 拉，国内几十 KB/s）。
        // 下面这条是同一份内容的官方中国镜像（字节 CDN），排在最前面优先命中。
        maven { url = uri("https://storage.flutter-io.cn/download.flutter.io") }
        // 同 settings.gradle.kts：国内镜像优先，官方源兜底
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
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
