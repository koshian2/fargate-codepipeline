import streamlit as st

# アプリのタイトル
st.title("Streamlitサンプルアプリ Ver.2")

# 説明文
st.write("これはDocker上で8080ポートを待ち受けするStreamlitアプリのサンプルです。")

# インタラクティブなウィジェット：スライダー
number = st.slider("数値を選択してください", 0, 100, 50)
st.write("選択した数値:", number)
