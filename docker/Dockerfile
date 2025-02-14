# ベースイメージとして公式のPython slimイメージを利用
FROM python:3.12-slim

# 作業ディレクトリを作成
WORKDIR /app

# 依存パッケージリストをコピー（必要であれば）
COPY requirements.txt .

# 必要なパッケージをインストール
RUN pip install --no-cache-dir -r requirements.txt

# アプリのソースコードをコンテナにコピー
COPY . .

# コンテナ内のポート8080を開放
EXPOSE 8080

# Streamlitアプリを起動（サーバーのアドレスを0.0.0.0に設定し、ポートを8080に変更）
CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8080"]
