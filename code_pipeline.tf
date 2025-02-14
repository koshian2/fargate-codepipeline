#########################
#  artifact bucket (S3)
#########################
resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = var.codepipeline_bucket_name
  force_destroy = true
}

#########################
#  IAMロール (CodePipeline)
#########################
resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "codepipeline.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "codepipeline_custom_policy" {
  name = "codepipeline-custom-policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      // CodePipeline 自体の操作権限
      {
        Effect = "Allow",
        Action = [
          "codepipeline:ListPipelines",
          "codepipeline:GetPipeline",
          "codepipeline:GetPipelineExecution",
          "codepipeline:StartPipelineExecution",
          "codepipeline:UpdatePipeline"
        ],
        Resource = "*"  // 必要に応じ対象パイプラインのARNに絞る
      },
      // S3 に対する権限 (アーティファクトストア)
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::${var.codepipeline_bucket_name}",
          "arn:aws:s3:::${var.codepipeline_bucket_name}/*"
        ]
      },
      // CodeBuild の起動・状態取得
      {
        Effect = "Allow",
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ],
        Resource = "arn:aws:codebuild:ap-northeast-1:${data.aws_caller_identity.current.account_id}:project/imagedefinitions-generator"
      },
      // ECR の読み取り権限 (ソースステージ用)
      {
        Effect = "Allow",
        Action = [
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ],
        Resource = aws_ecr_repository.my_repo.arn
      },
      // ECS の操作権限 (デプロイステージ用)
      {
        Effect = "Allow",
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition"
        ],
        Resource = "*"  // 必要に応じ対象のクラスター・サービスに絞る
      },
      // ecsTaskExecutionRole を渡すための権限を追加
      {
        Effect = "Allow",
        Action = "iam:PassRole",
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecsTaskExecutionRole"
      }      
    ]
  })
}

#########################
#  IAMロール (CodeBuild)
#########################
resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "codebuild.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_logs_policy" {
  name = "codebuild-logs-policy"
  role = aws_iam_role.codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
        # Resource = "arn:aws:logs:ap-northeast-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/imagedefinitions-generator*"
        // 絞るならこれ
      },
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ],
        Resource = [
          "arn:aws:s3:::${var.codepipeline_bucket_name}/*"
        ]
      },      
    ]
  })
}

resource "aws_iam_role_policy_attachment" "codebuild_policy_attach" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess"
}

#########################
#  CodeBuildプロジェクトで imagedefinitions.json を生成
#########################
resource "aws_codebuild_project" "imagedefinitions" {
  name         = "imagedefinitions-generator"
  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:6.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = false

    # CodeBuild内で利用する環境変数としてECRリポジトリのURLを設定
    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.my_repo.repository_url
    }
  }


  source {
    type      = "CODEPIPELINE"
    buildspec = <<EOF
version: 0.2

phases:
  build:
    commands:
      - echo "Generating imagedefinitions.json"
      # ここではコンテナ名 "streamlit" に対して、リポジトリURLと latest タグでイメージURIを作成
      - echo "[{\"name\":\"streamlit\",\"imageUri\":\"$${REPOSITORY_URI}:latest\"}]" > imagedefinitions.json
artifacts:
  files:
    - imagedefinitions.json
EOF
  }
}

#########################
#  CodePipeline定義
#########################
resource "aws_codepipeline" "ecs_pipeline" {
  name     = "ecs-deploy-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "ECR_Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "ECR"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        RepositoryName = aws_ecr_repository.my_repo.name
        ImageTag       = "latest"
      }

      run_order = 1
    }
  }

  stage {
    name = "Build"

    action {
      name             = "GenerateImagedefinitions"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["imagedefinitions"]
      configuration = {
        ProjectName = aws_codebuild_project.imagedefinitions.name
      }
      run_order = 1
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "DeployToECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["imagedefinitions"]
      configuration = {
        ClusterName = aws_ecs_cluster.this.name
        ServiceName = aws_ecs_service.fargate_service.name
        FileName    = "imagedefinitions.json"
      }
      run_order = 1
    }
  }
}

#########################
#  ECRにPush→PipelineがトリガーされるためのEventBridge
#########################
# CloudWatch Events（EventBridge）ルールの作成
resource "aws_cloudwatch_event_rule" "ecr_push_event_rule" {
  name = "ecr-push-trigger"
  event_pattern = jsonencode({
    "source": ["aws.ecr"],
    "detail-type": ["ECR Image Action"],
    "detail": {
      "result": ["SUCCESS"],
      "action-type": ["PUSH"],
      // さらに特定のリポジトリだけに絞る場合は以下のように
      "repository-name": [ aws_ecr_repository.my_repo.name ]
    }
  })
}

# CodePipelineを起動するためのIAMロール（EventBridgeからCodePipelineへStartPipelineExecution呼び出し）
resource "aws_iam_role" "eventbridge_invoke_codepipeline_role" {
  name = "eventbridge_invoke_codepipeline_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "events.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_codepipeline_policy" {
  name = "eventbridge_invoke_codepipeline_policy"
  role = aws_iam_role.eventbridge_invoke_codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = "codepipeline:StartPipelineExecution",
      Resource = aws_codepipeline.ecs_pipeline.arn
    }]
  })
}

# EventBridgeルールにターゲットとしてCodePipelineを設定
resource "aws_cloudwatch_event_target" "ecr_push_target" {
  rule      = aws_cloudwatch_event_rule.ecr_push_event_rule.name
  target_id = "codepipeline-target"
  arn       = aws_codepipeline.ecs_pipeline.arn
  role_arn  = aws_iam_role.eventbridge_invoke_codepipeline_role.arn
}
