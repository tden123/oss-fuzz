#!/bin/bash -eu
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################

PROJECT=gwt
PROJECT_GROUP_ID=org.gwtproject
PROJECT_ARTIFACT_ID=gwt-dev
MAIN_REPOSITORY=https://github.com/gwtproject/gwt/

MAVEN_ARGS="-Djavac.src.version=8 -Djavac.target.version=8 -Denforcer.skip=true -DskipTests"

function set_project_version_in_fuzz_targets_dependency {
  PROJECT_VERSION=$(cd $PROJECT && $MVN org.apache.maven.plugins:maven-help-plugin:3.2.0:evaluate -Dexpression=project.version -q -DforceStdout)
  # set dependency project version in fuzz-targets
  (cd fuzz-targets && $MVN versions:use-dep-version -Dincludes=$PROJECT_GROUP_ID:$PROJECT_ARTIFACT_ID -DdepVersion=$PROJECT_VERSION -DforceVersion=true)
}

cd project-parent

# LOCAL_DEV env variable need to be set in local development env
if [[ -v LOCAL_DEV ]]; then
  MVN=mvn

  # checkout latest project version
  git -C $PROJECT pull || git clone $MAIN_REPOSITORY $PROJECT
  # build tools for gwt
  git -C tools pull || git clone https://github.com/gwtproject/tools/ tools

  set_project_version_in_fuzz_targets_dependency

  #install
  mvn -pl $PROJECT install -DskipTests
  mvn -pl fuzz-targets install

else
  # Move seed corpus and dictionary.
  mv $SRC/{*.zip,*.dict} $OUT

  export JAVA_HOME="$OUT/open-jdk-8"
  mkdir -p $JAVA_HOME
  rsync -aL --exclude=*.zip "/usr/lib/jvm/java-8-openjdk-amd64/" "$JAVA_HOME"

  set_project_version_in_fuzz_targets_dependency

  #install
  (cd $PROJECT && $MVN install $MAVEN_ARGS -Dmaven.repo.local=$OUT/m2)
  $MVN -pl fuzz-targets install -Dmaven.repo.local=$OUT/m2

  # dependency:build-classpath won't work for ant generated jars
  cp $SRC/project-parent/gwt/build/lib/gwt-dev.jar $OUT/
  cp $SRC/project-parent/gwt/build/lib/gwt-user.jar $OUT/

  ALL_JARS="gwt-dev.jar gwt-user.jar"

  # build classpath
  $MVN -pl fuzz-targets dependency:build-classpath -Dmdep.outputFile=cp.txt -Dmaven.repo.local=$OUT/m2
  cp -r $SRC/project-parent/fuzz-targets/target/test-classes/ $OUT/
  RUNTIME_CLASSPATH_ABSOLUTE="$(cat fuzz-targets/cp.txt):$OUT/test-classes:$(echo $ALL_JARS | xargs printf -- "$OUT/%s:")"
  RUNTIME_CLASSPATH_RELATIVE=$(echo $RUNTIME_CLASSPATH_ABSOLUTE | sed "s|$OUT|.|g")

  for fuzzer in $(find $SRC/project-parent/fuzz-targets -name '*Fuzzer.java'); do
    fuzzer_basename=$(basename -s .java $fuzzer)

    # Create an execution wrapper for every fuzztarget
    echo "#!/bin/bash
  # LLVMFuzzerTestOneInput comment for fuzzer detection by infrastructure.
  if [[ \"\$@\" =~ (^| )-runs=[0-9]+($| ) ]]; then
    mem_settings='-Xmx1900m -Xss900k'
  else
    mem_settings='-Xmx2048m -Xss1024k'
  fi
  this_dir=\$(dirname \"\$0\")
  JAVA_HOME=\"\$this_dir/open-jdk-8/\" \
  ./open-jdk-8/bin/java -cp $RUNTIME_CLASSPATH_RELATIVE \
  \$mem_settings \
  com.code_intelligence.jazzer.Jazzer \
  --target_class=com.example.$fuzzer_basename \
  \$@" > $OUT/$fuzzer_basename
    chmod u+x $OUT/$fuzzer_basename
  done

fi