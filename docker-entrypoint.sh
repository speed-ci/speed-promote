#!/bin/bash
set -e

source /init.sh

printmainstep "Déclenchement de la promotion du macroservice"
printstep "Vérification des paramètres d'entrée"
init_env
int_gitlab_api_env

declare -A PROMOTIONS=(["DEV"]="RECSMA" ["RECSMA"]="INT" ["RECSEP"]="INT" ["INT"]="PREPROD" ["PREPROD"]="PROD")
SOURCE_BRANCH=`echo "$CI_ENVIRONMENT_NAME" | tr '[:upper:]' '[:lower:]'`
DEST_BRANCH=`echo "${PROMOTIONS[$CI_ENVIRONMENT_NAME]}" | tr '[:upper:]' '[:lower:]'`

printinfo "SOURCE_BRANCH: $SOURCE_BRANCH"
printinfo "DEST_BRANCH: $DEST_BRANCH"

if [[ -z $CI_ENVIRONMENT_NAME ]];then
    printerror "La variable CI_ENVIRONMENT_NAME de l'environnement source n'est pas renseignée"
    exit 1
fi

if [[ -z $DEST_ENV ]];then
    printerror "L'environnement de destination pour la promotion de $CI_ENVIRONMENT_NAME est inconnu"
    exit 1
fi

printstep "Préparation du projet $PROJECT_NAMESPACE/$PROJECT_NAME"
PROJECT_ID=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects?search=$PROJECT_NAME" | jq --arg project_namespace "$PROJECT_NAMESPACE" '.[] | select(.namespace.name == "\($project_namespace)") | .id'`

GITLAB_CI_USER_MEMBERSHIP=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/members?query=$GITLAB_CI_USER" | jq .[0]`
if [[ $GITLAB_CI_USER_MEMBERSHIP == "null" ]]; then 
    printinfo "Ajout du user $GITLAB_CI_USER manquant au projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/members" -d "user_id=$GITLAB_CI_USER_ID" -d "access_level=40"
fi

printstep "Promotion du macroservice de $SOURCE_BRANCH à $DEST_BRANCH"
DEST_BRANCH_FOUND=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches/$DEST_BRANCH" | jq .name`

if [[ $DEST_BRANCH_FOUND == "null" ]]; then
    printinfo "Création de la branche $DEST_BRANCH manquante sur le projet $PROJECT_NAMESPACE/$PROJECT_NAME"
    myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/branches" -d "branch=$DEST_BRANCH" -d "ref=$SOURCE_BRANCH" | jq .

else
    LAST_NEW_COMMIT=`myCurl --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/repository/compare?from=$DEST_BRANCH&to=$SOURCE_BRANCH" | jq -r .commit.id`
    if [[ $LAST_NEW_COMMIT != "null" ]]; then
        printinfo "Mise à jour de la branche $DEST_BRANCH avec les derniers commits de $SOURCE_BRANCH"
        PROMOTION_MR_IID=`myCurl --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests" -d "source_branch=$SOURCE_BRANCH" -d "target_branch=$DEST_BRANCH" -d "title=chore(promotion): Promote macroservice from $SOURCE_BRANCH branch to $DEST_BRANCH branch" | jq .iid`
        printinfo "Lien d'accès à la merge request : $GITLAB_URL/$PROJECT_NAMESPACE/$PROJECT_NAME/merge_requests/$PROMOTION_MR_IID"
        myCurl --request PUT --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID/merge_requests/$PROMOTION_MR_IID/merge" | jq .
    else
        printinfo "Aucune différence entre les branches $SOURCE_BRANCH et $DEST_BRANCH, promotion inutile"
    fi
fi
