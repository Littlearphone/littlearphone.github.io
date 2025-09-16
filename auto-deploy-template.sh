#!/bin/bash

root_path=$(pwd)

project_folder="littlearphone.github.io"
project_path="${root_path}/${project_folder}"
commit_history="${root_path}/commit-history"
maven_version="apache-maven-3.9.11"
maven_path="${root_path}/${maven_version}"

if [ -f ${commit_history} ]; then
  last_hash=$(<${commit_history})
  echo "last hash: " $last_hash
fi

# rm -rf ${project_path}

if [ ! -d ${project_path} ]; then
  git clone https://github.com/Littlearphone/${project_folder}.git
fi

if [ ! -d ${project_path} ]; then
  echo 'download code failed'
  exit
fi

cd ${project_path}

git reset --hard
git pull

curr_hash=$(git rev-parse HEAD)
echo "curr hash: " $curr_hash

if [[ "$last_hash" == "$curr_hash" ]]; then 
  echo 'no need to build'
  exit
fi

if [ ! -d ${maven_path} ]; then
  echo "maven path does not exist."
  if [ -f ${maven_path}.zip ]; then
    rm -rf ${maven_path}.zip
  fi
  curl -o ${maven_path}.zip https://dlcdn.apache.org/maven/maven-3/3.9.11/binaries/${maven_version}-bin.zip
  unzip ${maven_path}.zip -d ${root_path}
fi

"${maven_path}/bin/mvn" -version

echo $curr_hash > ${commit_history}
